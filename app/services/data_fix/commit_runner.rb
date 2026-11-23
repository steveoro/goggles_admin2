# frozen_string_literal: true

module DataFix
  #
  # = DataFix::CommitRunner
  #
  # The Phase 6 commit of one source (moved from DataFix::CommitsController#commit_phase6): gates, then
  # Import::Committers::Main#commit_all, the Outbox script (registered INSIDE the local transaction through the
  # +before_commit:+ callable, numbered by Outbox::Sequence), DataFix::CommitArchiver.finalize, the ops event and the
  # triggered season health runs. Uses no request state (it runs inside DataFixCommitJob).
  #
  # Outcome states (Outcome#commit_state): 'committed', 'committed_archive_failed' (the local DB is committed and the
  # script registered: only the bookkeeping failed, see #retry_archive!), 'failed' (rolled back), 'refused' (a gate
  # stopped it before anything was written).
  #
  # == Usage
  #   outcome = DataFix::CommitRunner.new(source_path:, progress: Import::Progress::Ops.new(report),
  #                                       actor_user_id: report.requested_by_user_id).call
  #
  class CommitRunner
    # A gate stopping the commit before anything is written (shown as a flash by the POST, stored on the report by
    # the job): message, i18n-free +flash_key+ and the review step to open.
    Refusal = Data.define(:message, :flash_key, :step, :step_params)

    Outcome = Data.define(:commit_state, :stats, :error_message, :archive_error, :script, :season_id, :done_dir,
                          :first_error_phase, :meeting_id, :log_full_path, :health_run_ids, :db_generation_after) do
      def committed? = commit_state.to_s.start_with?('committed')
      def sql_filename = script&.filename
      def script_id = script.respond_to?(:id) ? script.id : nil
    end

    # First logged error entity => phase to review.
    PHASE_HINTS = {
      'Meeting' => 1, 'Calendar' => 1, 'City' => 1, 'SwimmingPool' => 1, 'MeetingSession' => 1,
      'Team' => 2, 'TeamAffiliation' => 2, 'Swimmer' => 3, 'Badge' => 3, 'MeetingEvent' => 4,
      'MeetingProgram' => 5, 'MeetingIndividualResult' => 5, 'MeetingRelayResult' => 5, 'MeetingRelaySwimmer' => 5,
      'Lap' => 5, 'RelayLap' => 5
    }.freeze
    # Season health groups whose triggered runs are shown by the commit report.
    REPORT_HEALTH_GROUPS = %w[results badges].freeze

    attr_reader :source_path, :file_path, :progress, :actor_user_id

    # == Params
    # - source_path: canonical LT4 working copy (results.new); file_path: the path the operator opened (its LT2
    #   counterpart is archived too), defaults to +source_path+;
    # - progress: Import::Progress sink; actor_user_id: the operator who clicked Commit (script origin).
    def initialize(source_path:, file_path: nil, progress: Import::Progress::Null.new, actor_user_id: nil, source_resolver: nil)
      @source_path = source_path.to_s
      @file_path = (file_path.presence || source_path).to_s
      @progress = progress || Import::Progress::Null.new
      @actor_user_id = actor_user_id
      @source_resolver = source_resolver
    end

    def source_resolver
      @source_resolver ||= DataFix::SourceResolver.new
    end

    def phase_path(phase) = source_resolver.default_phase_path_for(source_path, phase)

    def log_full_path
      File.join(File.dirname(source_path), "#{File.basename(source_path, '.json')}.log")
    end

    # True for a result-free source with nothing staged: only Phase 1 is committed.
    def result_free?
      return @result_free unless @result_free.nil?

      @result_free = source_resolver.source_result_free?(source_path) && staged_count.zero?
    end

    def staged_count
      @staged_count ||= GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).count +
                        GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).count
    end

    # The synchronous gates of the former controller (missing phase files, meeting structure of a result-free source,
    # nothing staged): a Refusal, or nil when the commit may run.
    def precheck
      missing = [1]
      missing += [2, 3, 4, 5] unless result_free?
      missing = missing.reject { |phase| File.exist?(phase_path(phase)) }
      if missing.any?
        return Refusal.new(message: I18n.t('data_import.data_fix.missing_phase_files', list: missing.join(', ')),
                           flash_key: :error, step: 5, step_params: {})
      end
      return structure_refusal if result_free?
      return nil if staged_count.positive?

      Refusal.new(message: I18n.t('data_import.data_fix.no_phase5_data'), flash_key: :error, step: 5, step_params: { rescan: 1 })
    end

    # Runs the commit. Never raises for a commit failure (see Outcome#commit_state).
    def call
      refusal = precheck
      return refused_outcome(refusal.message) if refusal

      # Manifest-extracted sources flag the committed Meeting as manifest-only (new meetings only).
      source_resolver.mark_phase1_manifest_flag!(phase_path(1)) if result_free? && source_resolver.parsed_source_json(source_path).dig('_meta',
                                                                                                                                       'meeting_only') == true

      committer = Import::Committers::Main.new(
        phase1_path: phase_path(1), phase2_path: phase_path(2), phase3_path: phase_path(3),
        phase4_path: phase_path(4), phase5_path: phase_path(5), source_path:, log_path: log_full_path, progress:
      )
      state = { commit_state: 'failed', error_message: nil, archive_error: nil, stats: nil, season_id: nil, done_dir: nil,
                first_error_phase: nil, script: nil }

      begin
        # The SQL script is registered in the Outbox INSIDE the local transaction (before_commit): a failed write rolls
        # the local commit back.
        state[:stats] = committer.commit_all(before_commit: lambda { |sql|
          state[:script] = write_commit_script(sql:, committer:)
        })
        # Guard: if any errors were accumulated, treat as failure even if transaction did not raise
        raise StandardError, "Commit completed with #{state[:stats][:errors].count} errors. Check #{log_full_path} for details." if state[:stats][:errors].any?

        state[:commit_state] = 'committed'
      rescue StandardError => e
        if committer.committed?
          # (e.g. the log file write failed after the local COMMIT: the commit and its script stand)
          Rails.logger.error("[Phase 6 Commit] committed, then: #{e.class}: #{e.message}")
          state[:commit_state] = 'committed'
        else
          # The local transaction rolled back: a script written meanwhile must not stay pushable.
          Outbox::Writer.discard!(state[:script])
          state[:script] = nil
          state[:error_message] = "Phase 6 commit failed: #{e.message}"
          Rails.logger.error("[Phase 6 Commit] #{state[:error_message]}")
          Rails.logger.error(e.backtrace.join("\n"))
          state[:stats] ||= committer.respond_to?(:stats) ? committer.stats : nil
          state[:stats] ||= { errors: [] }
          state[:first_error_phase] = first_error_phase_for(committer)
        end
      end

      archive!(state) if state[:commit_state] == 'committed'
      finish(state, committer)
    end

    # "Committed, archiving failed": runs the (idempotent) archiving step again. Never commits anything.
    # Returns { commit_state:, season_id:, done_dir:, archive_error: }.
    def retry_archive!
      archive = archive_commit_files
      record_archive_event(season_id: archive[:season_id], error: nil)
      { commit_state: 'committed', season_id: archive[:season_id], done_dir: archive[:done_dir], archive_error: nil }
    rescue StandardError => e
      error = "#{e.class}: #{e.message}"
      season_id = Outbox.season_id_for(File.basename(File.dirname(source_path)))
      record_archive_event(season_id:, error:)
      { commit_state: 'committed_archive_failed', season_id:, done_dir: nil, archive_error: error }
    end

    private

    def structure_refusal
      report = Import::StructureValidator.new(phase1_data: PhaseFileManager.new(phase_path(1)).data)
      return nil if report.valid?

      count = report.error_messages.size
      Refusal.new(message: I18n.t('data_import.data_fix.invalid_meeting_structure',
                                  errors: report.error_messages.first(3).join(' • '), more: count > 3 ? " (+#{count - 3} more)" : ''),
                  flash_key: :error, step: 1, step_params: {})
    end

    def refused_outcome(message)
      Outcome.new(commit_state: 'refused', stats: nil, error_message: message, archive_error: nil, script: nil, season_id: nil,
                  done_dir: nil, first_error_phase: nil, meeting_id: nil, log_full_path:, health_run_ids: {}, db_generation_after: nil)
    end

    def archive!(state)
      # Move source+phase files to results.done/, clean the staging tables and append the post-commit log section.
      archive = archive_commit_files
      state[:season_id] = archive[:season_id]
      state[:done_dir] = archive[:done_dir]
    rescue StandardError => e
      # The local DB is committed and the script registered: only the bookkeeping failed ("Retry archiving").
      state[:commit_state] = 'committed_archive_failed'
      state[:archive_error] = "#{e.class}: #{e.message}"
      state[:season_id] = Outbox.season_id_for(File.basename(File.dirname(source_path)))
      Rails.logger.error("[Phase 6 Commit] archiving failed: #{state[:archive_error]}")
    end

    def finish(state, committer)
      committed = state[:commit_state].start_with?('committed')
      generation = DataFix::Pipeline.bump_db_generation! if committed
      record_commit_event(**state.slice(:commit_state, :season_id, :stats), sql_filename: state[:script]&.filename,
                                                                            error_message: state[:error_message] || state[:archive_error])
      health_run_ids = enqueue_health_runs(season_id: state[:season_id], commit_state: state[:commit_state])
      mark_source_committed! if committed
      Outcome.new(commit_state: state[:commit_state], stats: state[:stats], error_message: state[:error_message],
                  archive_error: state[:archive_error], script: state[:script], season_id: state[:season_id],
                  done_dir: state[:done_dir], first_error_phase: state[:first_error_phase], meeting_id: committer.meeting_id,
                  log_full_path:, health_run_ids:, db_generation_after: generation)
    end

    # Registers the commit SQL script in the Outbox (called inside the local transaction, see Main#commit_all):
    # results.new/<season folder>/NNNN-<source base>.sql, under the data root of the source.
    def write_commit_script(sql:, committer:)
      Outbox::Writer.write!(
        kind: 'commit', name: File.basename(source_path, '.json'), sql:, folder: File.basename(File.dirname(source_path)),
        data_root: Outbox.data_root_for(source_path),
        origin: { 'producer' => 'data_fix.commit', 'source_base' => File.basename(source_path, '.json').delete_suffix('-lt4'),
                  'source_file' => File.basename(source_path), 'meeting_id' => committer.meeting_id,
                  'fin_event_id' => source_fin_event_id, 'actor_user_id' => actor_user_id }.compact
      )
    end

    # FIN event id of the source file (top-level meetingURL / manifestURL), or nil. Never raises.
    def source_fin_event_id
      data = source_resolver.parsed_source_json(source_path)
      FINEventId.parse_any(data['meetingURL'], data['manifestURL'])
    rescue StandardError
      nil
    end

    # Moves the source + phase files to results.done/ etc. (see DataFix::CommitArchiver).
    def archive_commit_files
      DataFix::CommitArchiver.finalize(
        source_path:, lt2_source_path: file_path.gsub('-lt4.json', '.json'), phase1_path: phase_path(1),
        phase_paths: (1..5).map { |phase| phase_path(phase) }, log_full_path:
      )
    end

    # Phase to review from the first logged validation error (best effort, never raises).
    def first_error_phase_for(committer)
      return unless committer.respond_to?(:logger) && committer.logger.respond_to?(:entries)

      first_error_entry = Array(committer.logger.entries).find { |entry| entry[:level] == :error }
      PHASE_HINTS[first_error_entry[:entity_type].to_s] if first_error_entry
    rescue StandardError
      nil
    end

    # Appends 'datafix.committed' / 'datafix.archive_failed' / 'datafix.commit_failed' to the ops log (never raises).
    def record_commit_event(commit_state:, season_id:, stats:, sql_filename:, error_message:)
      Ops.safely do
        first_error = error_message || Array(stats&.dig(:errors)).first
        kind, level = { 'committed' => %w[datafix.committed success],
                        'committed_archive_failed' => %w[datafix.archive_failed warning] }
                      .fetch(commit_state, %w[datafix.commit_failed error])
        Ops.record_event!(
          kind:, level:, actor: 'operator',
          season_id: season_id || Integer(File.basename(File.dirname(source_path)), exception: false),
          subject_type: 'source', subject_key: source_path,
          data: { 'sql_filename' => sql_filename, 'first_error' => first_error&.to_s&.truncate(500) }.compact,
          link_path: commit_state == 'failed' ? nil : Rails.application.routes.url_helpers.outbox_path(focus: sql_filename)
        )
      end
    end

    # Appends 'datafix.archived' (retry succeeded) or 'datafix.archive_failed' to the ops log (never raises).
    def record_archive_event(season_id:, error:)
      Ops.record_event!(
        kind: error ? 'datafix.archive_failed' : 'datafix.archived', level: error ? 'warning' : 'success',
        actor: 'operator', season_id:, subject_type: 'source', subject_key: source_path,
        data: { 'error' => error&.truncate(500) }.compact
      )
    end

    # (phase 06) After a local commit, queues the read-only data health checks of the season (trigger 'post_commit',
    # 'maintenance' worker): first the 'results' and 'badges' runs shown by the commit report, then every other group.
    # Returns { group => Ops::HealthRun id } for the report groups. Never fails the commit flow.
    def enqueue_health_runs(season_id:, commit_state:)
      return {} unless season_id.present? && commit_state.to_s.start_with?('committed') && Ops.available?

      groups = Health::SeasonScope.new.groups_for(season_id.to_i).map(&:to_s)
      ids = (REPORT_HEALTH_GROUPS & groups).to_h do |group|
        run = Health::SeasonRunJob.enqueue(season_id: season_id.to_i, group:, trigger: 'post_commit')
        run ||= Ops::HealthRun.for_season(season_id.to_i).for_group(group).pending.order(:id).last
        [group, run&.id]
      end
      Health::SeasonRunJob.enqueue_season(season_id: season_id.to_i, trigger: 'post_commit')
      ids.compact
    rescue StandardError => e
      Rails.logger.error("[Phase 6 Commit] health runs not queued: #{e.class}: #{e.message}")
      ids || {}
    end

    # Stage 'committed' on the Ops::PipelineSource row (the base stays the key in results.done).
    def mark_source_committed!
      Ops.safely do
        next unless Ops.available?

        row = Ops::PipelineSource.for_path!(source_path)
        row.update!(stage: 'committed', committed_at: Time.current, stage_reason: nil, stage_details: {}, lease_owner: nil,
                    lease_expires_at: nil)
        season_id = row.season_id
        SeasonBoard::Snapshot.invalidate!(season_id) if season_id.to_i.positive?
      end
    end
  end
end
