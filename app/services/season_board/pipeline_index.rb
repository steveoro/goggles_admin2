# frozen_string_literal: true

require 'digest'

module SeasonBoard
  #
  # = SeasonBoard::PipelineIndex
  #
  # Pipeline facts of the Data-Fix sources of one season (phase 10), read from the ops DB with three small queries per
  # board build (pipeline_sources of the season, their phase_verdicts, the latest 'prepare' pipeline_runs row of each)
  # and reconciled with the files found by DiskIndex: a row is looked up by the base of the entry's active source
  # (review source, else results / structure / result-free source). A row without files is never reported (its stored
  # stage is left alone); files without a row get no facts, so the board keeps today's states (a pre-09 phase file
  # is adopted as edited and stays :in_review).
  #
  # Without the ops DB every lookup answers nil. A failed ops read is contained (the board falls back to the former
  # states) but recorded: #read_error? tells the planner not to trust the facts of this build (fail closed).
  #
  # == Facts (see Facts below)
  # - stage / review_phase / review_count / new_teams / new_swimmers: the stored Ops::PipelineSource summary;
  # - verdicts?: verdict rows exist; fresh?: each of the five verdicts was computed after the newest of the files its
  #   cache fingerprint covers (DataFix::Pipeline#fingerprint: the working copy and the phase files 1..N, never the LT2
  #   once an LT4 working copy exists), and under the current data_fix.db_generation (or no new entity depends on it);
  # - newest_file_at: the newest mtime among the working copy and all the phase files (the planner compares it with the
  #   end of the last prepare run);
  # - preparing?: a prepare job holds the lease, or a prepare run is running (not stale); a run merely queued is not
  #   "preparing" (0.10.99: the row keeps its state and its review link until the job starts);
  # - prepare_queued?: a prepare run is queued (not stale) and not running yet: state_and_detail answers
  #   [:prepare_queued, {}] unless a review state (needs review, ready to commit) still holds, and the board row counts
  #   as busy (no second prepare, no Retry);
  # - leased?: a prepare job holds the source lease (the Data-Fix pages refuse edits: the board locks the review links);
  # - held?: the operator held the row (pipeline_sources.auto_prepare false);
  # - edited_recorded?: a verdict row records operator edits / an adopted file (the planner re-checks the files);
  # - stale_phases: phases whose stored verdict is 'stale'; db_behind?: new entities and a newer db generation;
  # - collision_bases: the other sources named by a phase 5 'collisions' issue;
  # - last_run: the latest prepare Ops::PipelineRun (or nil); prepare_failed?: the last prepare failed (or the stage is
  #   'failed') and the source did not change since.
  #
  class PipelineIndex # rubocop:disable Metrics/ClassLength
    # Tolerance between a verdict's checked_at and the file mtimes.
    FRESH_TOLERANCE = 1.second
    STAGES_IN_REVIEW = %w[needs_review blocked].freeze

    Facts = Data.define(
      :source_id, :base, :source_path, :stage, :stage_reason, :review_phase, :review_count, :new_teams, :new_swimmers, :held,
      :preparing, :verdict_count, :fresh, :edited_recorded, :stale_phases, :db_behind, :collision_bases, :last_run,
      :failed, :source_changed, :failed_phase, :failed_message, :highest_phase, :leased, :newest_file_at, :prepare_queued
    ) do
      def initialize(leased: false, newest_file_at: nil, prepare_queued: false, **) = super

      def held? = held
      def preparing? = preparing
      def prepare_queued? = prepare_queued
      def leased? = leased
      def verdicts? = verdict_count.positive?
      def fresh? = fresh
      def edited_recorded? = edited_recorded
      def db_behind? = db_behind

      # Last prepare failed (or the stage is 'failed') and the source is unchanged since.
      def prepare_failed? = failed && !source_changed && !preparing

      # The source failed, but its file changed since (the planner may prepare it again).
      def failed_but_changed? = failed && source_changed

      # Every verdict clean and fresh.
      def ready_to_commit? = !preparing && stage == 'ready_to_commit' && fresh

      # A phase needs a decision (review / blocked), or a stored "ready" is no longer current.
      def needs_review?
        return false if preparing || !verdicts?

        STAGES_IN_REVIEW.include?(stage) || outdated?
      end

      # A stored "ready to commit" whose checks are no longer current (a file changed since, or the db generation moved).
      def outdated? = stage == 'ready_to_commit' && !fresh

      def blocked? = stage == 'blocked'

      # Step to resume at for :needs_review.
      def review_step = review_phase || highest_phase || 1

      # [state, detail] of the facts, with the board rules (StateResolver) plus :preparing and :prepare_queued (a queued
      # prepare wins over a failure, whose Retry it is, and over no state at all; never over a review state, whose link
      # stays usable meanwhile); nil without a pipeline state. (Phase 15: the Sources Results tab and the non-FIN
      # sources of the board summary, which have no activity log entry.)
      def state_and_detail
        return [:preparing, {}] if preparing?
        return [:prepare_queued, {}] if prepare_queued? && !reviewable?
        return [:prepare_failed, { phase: failed_phase, message: failed_message }] if prepare_failed?
        return [:needs_review, review_detail] if needs_review?

        [:ready_to_commit, { new_teams:, new_swimmers: }] if ready_to_commit?
      end

      # A review state holds (needs review, ready to commit) and no failure comes first.
      def reviewable? = !prepare_failed? && (needs_review? || ready_to_commit?)

      # Detail of the :needs_review state (+outdated: true+ for a "ready to commit" whose checks are outdated).
      def review_detail
        detail = { step: review_step, count: review_count, blocked: blocked? }
        outdated? ? detail.merge(outdated: true) : detail
      end
    end

    attr_reader :season_id

    # == Params
    # - season_id: board season id;
    # - generation: current data_fix.db_generation (default: DataFix::Pipeline.db_generation, read once).
    def initialize(season_id:, generation: nil)
      @season_id = season_id.to_i
      @generation = generation
    end

    # Facts for a DiskIndex::Entry (nil when its active source has no ops row, or without the ops DB).
    def for_entry(entry)
      source = active_source(entry)
      return nil unless source

      row = rows_by_base[source.base]
      row && build_facts(row, source)
    end

    # The source the facts are about: the one in review, else the newest results / structure / result-free one.
    def self.active_source(entry)
      return nil unless entry

      entry.review_source || entry.results_source || entry.structure_source || entry.result_free_source
    end

    # The file the Data-Fix pipeline of +source+ (a DiskIndex::Source) reads: +stored_path+ (Ops::PipelineSource#
    # source_path, i.e. DataFix::Pipeline#source_path), else the LT4, else the LT2. Never the LT2 when an LT4 working copy
    # exists: the stored path stays on the LT2 when a prepare scheduled from it never started, and a CSV crawl may
    # rewrite a same-named LT2 without changing the working copy. (Also SeasonBoard::PipelinePlanner, RowFlags.)
    def self.working_copy(stored_path, source)
      path = stored_path.presence
      path = nil if path && source.lt4_path && path.to_s == source.lt2_path.to_s
      path || source.lt4_path || source.lt2_path
    end

    delegate :active_source, to: :class

    # Stored rows of the season (Hash base => Ops::PipelineSource), loaded once.
    def rows_by_base
      @rows_by_base ||= read({}) do
        next {} unless Ops.available?

        Ops::PipelineSource.where(season_id: @season_id).index_by(&:base)
      end
    end

    def generation
      @generation ||= DataFix::Pipeline.db_generation
    end

    # True when an ops query of this index failed (its facts are incomplete: automatic work must not rely on them).
    def read_error? = @read_error == true

    private

    def build_facts(row, source) # rubocop:disable Metrics/AbcSize
      verdicts = verdicts_by_source.fetch(row.id, [])
      run = last_runs.fetch(row.id, nil)
      failed = failed?(row, run, verdicts)
      Facts.new(
        source_id: row.id, base: row.base, source_path: row.source_path, stage: row.stage, stage_reason: row.stage_reason,
        review_phase: row.review_phase, review_count: row.review_count.to_i, new_teams: row.new_teams_count.to_i,
        new_swimmers: row.new_swimmers_count.to_i, held: row.held?, preparing: preparing?(row, run),
        verdict_count: verdicts.size, fresh: fresh?(row, verdicts, source), edited_recorded: edited_recorded?(verdicts),
        stale_phases: verdicts.select { |verdict| verdict.status == 'stale' }.map(&:phase).sort,
        db_behind: db_behind?(row), collision_bases: collision_bases(verdicts), last_run: run,
        failed:, source_changed: failed && source_changed?(row, run, source), failed_phase: failed_phase(run, verdicts),
        failed_message: failed_message(run, verdicts), highest_phase: source.phase, leased: row.leased_by_job?,
        newest_file_at: covered_mtime(row, source, source.phase_paths.keys.max), prepare_queued: prepare_queued?(row, run)
      )
    end

    # == Queries (once per index)

    def verdicts_by_source
      @verdicts_by_source ||= read({}) do
        ids = rows_by_base.values.map(&:id)
        ids.empty? ? {} : Ops::PhaseVerdict.where(pipeline_source_id: ids).to_a.group_by(&:pipeline_source_id)
      end
    end

    def last_runs
      @last_runs ||= read({}) do
        ids = rows_by_base.values.map(&:id)
        next {} if ids.empty?

        latest = Ops::PipelineRun.where(pipeline_source_id: ids, kind: 'prepare').group(:pipeline_source_id).select('MAX(id)')
        Ops::PipelineRun.where(id: latest).index_by(&:pipeline_source_id)
      end
    end

    # Runs an ops read, returning +default+ (and flagging #read_error?) when it raises.
    def read(default)
      yield
    rescue StandardError => e
      @read_error = true
      Rails.logger.warn("[SeasonBoard::PipelineIndex] ops read failed: #{e.class}: #{e.message}")
      default
    end

    # == Facts helpers

    # A job holds the lease, or the prepare run is running (a queued run is not preparing yet).
    def preparing?(row, run)
      row.leased_by_job? || (run.present? && run.status == 'running' && !run.stale?)
    end

    # The latest prepare run is queued (not stale), and no job is preparing the source yet.
    def prepare_queued?(row, run)
      run.present? && run.status == 'queued' && !run.stale? && !preparing?(row, run)
    end

    # Five verdicts, each computed after the newest of the files its fingerprint covers, under the current generation
    # (when it matters). (Each verdict is cached and reused while its own files are unchanged: verdict 1 is older than the
    # phase 5 file of a source prepared in one go, and still current.)
    def fresh?(row, verdicts, source)
      return false if verdicts.size < DataFix::Pipeline::PHASES.size
      return false unless verdicts.all? { |verdict| verdict_current?(verdict, row, source) }

      !db_behind?(row)
    end

    def verdict_current?(verdict, row, source)
      return false if verdict.checked_at.nil?

      newest = covered_mtime(row, source, verdict.phase)
      newest.nil? || verdict.checked_at >= newest - FRESH_TOLERANCE
    end

    # Newest mtime among the working copy and the phase files 1..+phase+ of the source (what the cache fingerprint of
    # the verdict of +phase+ reads), or nil.
    def covered_mtime(row, source, phase)
      paths = [self.class.working_copy(row.source_path, source), *source.phase_paths.select { |number, _path| phase && number <= phase }.values]
      paths.compact.filter_map { |path| mtime(path) }.max
    end

    def db_behind?(row)
      row.db_generation.to_i < generation && (row.new_teams_count.to_i + row.new_swimmers_count.to_i).positive?
    end

    def edited_recorded?(verdicts)
      verdicts.any? do |verdict|
        counts = verdict.counts.to_h
        verdict.operator_edited_at.present? || counts['_edited'] == true || counts['_adopted'] == true
      end
    end

    def collision_bases(verdicts)
      verdict = verdicts.find { |row| row.phase == 5 && row.status == 'blocked' }
      issue = verdict && Array(verdict.issues).find { |row| row['code'] == 'collisions' }
      Array(issue && issue['details']).map { |name| Ops::PipelineSource.base_for(name) }.uniq
    end

    # The last prepare failed (and no build or verdict came after it), or the stored stage is 'failed'.
    def failed?(row, run, verdicts)
      return true if row.stage == 'failed'
      return false unless run&.status == 'failed'

      latest = verdicts.filter_map(&:checked_at).max
      latest.nil? || run.finished_at.nil? || latest <= run.finished_at + FRESH_TOLERANCE
    end

    # The source changed since the failure: its SHA256 differs from the one stored at the failure, or the LT2 / LT4
    # file is newer than the failed run.
    def source_changed?(row, run, source)
      newer_than?(source, run&.finished_at) || sha_changed?(row)
    end

    # The LT2 / LT4 file of the source is newer than +time+.
    def newer_than?(source, time)
      time.present? && [source.lt2_path, source.lt4_path].compact.any? { |path| mtime(path)&.>(time) }
    end

    # The stored source SHA256 of the failure differs from the current one.
    def sha_changed?(row)
      return false if row.failed_source_sha256.blank? || row.source_path.blank? || !File.exist?(row.source_path)

      Digest::SHA256.file(row.source_path).hexdigest != row.failed_source_sha256
    rescue SystemCallError
      false
    end

    def failed_phase(run, verdicts)
      run&.phase || verdicts.select { |verdict| verdict.status == 'failed' }.map(&:phase).min
    end

    def failed_message(run, verdicts)
      return run.error.to_s.truncate(200) if run&.status == 'failed' && run.error.present?

      verdict = verdicts.find { |row| row.status == 'failed' }
      verdict&.counts.to_h['_message'].to_s.truncate(200).presence
    end

    def mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end
  end
end
