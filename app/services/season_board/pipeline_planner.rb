# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::PipelinePlanner
  #
  # State-driven automation of the Season board (phase 10), the sibling of CrawlPlanner: one pass reads the board
  # (a full Builder build, stored as the board summary, with the ops pipeline facts of each row) and queues, through
  # SeasonBoard::Scheduler, what each row needs next. A lost link in the chain is picked up by the next pass
  # (PipelinePlannerJob: after every crawl, extraction, successful prepare and watcher check, plus every 15 minutes).
  #
  # Scope: the board season only (SeasonBoard::Builder.latest_season, the season the board shows by default), FIN
  # rows only (unmatched sources wait for phase 15). It never queues anything that commits or pushes.
  #
  # == Rules (row state => job), each checked against the switches (DataFix::Automation) before the enqueue
  # - :results_ready                         => DataFixPrepareJob(up_to: 5)          [auto_prepare]
  # - :structure_ready, :crawled_no_manifest => DataFixPrepareJob(up_to: 1)          [auto_prepare]
  # - :needs_review / :ready_to_commit with new entities and a newer db generation
  #                                          => DataFixPrepareJob(refresh_new_entities) [auto_prepare]
  # - :needs_review / :ready_to_commit with stale or outdated verdicts
  #                                          => DataFixPrepareJob(rebuild_stale)     [auto_prepare]
  # - phase 5 blocked by an import_key collision whose other source has been committed since
  #                                          => DataFixPrepareJob(rebuild_stale, phases: [5]) [auto_prepare]
  # - a failed source whose file changed since the failure => DataFixPrepareJob(up_to: 5) [auto_prepare]
  # - :manifest_pending                      => ManifestExtractJob (origin :auto)    [auto_extract]
  #   (engine preflight once per pass; at most MAX_EXTRACT_ATTEMPTS unsuccessful automatic attempts per PDF: every
  #   automatic run not ended 'done' counts, i.e. failed, refused, and queued/running ones left stale by a dead worker;
  #   the last attempt at least MIN_EXTRACT_INTERVAL ago)
  # - :prepare_failed (source unchanged), :in_review, :sql_pending, done/cancelled/unlinked rows => nothing.
  #
  # Skipped always: busy rows (crawl/extraction/prepare queued or running), held rows (pipeline_sources.auto_prepare
  # false), a prepare run of the source finished less than REQUEUE_AFTER ago (REFUSED_REQUEUE_AFTER for a refused
  # one), and ANY source holding an edited phase (checked on the phase files themselves: the operator opts in with
  # the row's "Prepare" button). At most MAX_PREPARES_PER_PASS prepares and MAX_EXTRACTIONS_PER_PASS extractions are
  # queued per pass.
  #
  # Fail closed: a switch that cannot be read is off (DataFix::Automation); when the ops facts of the build could not
  # be read (PipelineIndex#read_error?) no prepare is queued in that pass; an unreadable attempt count gives up, an
  # unreadable last-attempt time counts as recent; an unreadable edit check counts as edited.
  #
  class PipelinePlanner # rubocop:disable Metrics/ClassLength
    MAX_PREPARES_PER_PASS = 5
    MAX_EXTRACTIONS_PER_PASS = 3
    MAX_EXTRACT_ATTEMPTS = 3
    MIN_EXTRACT_INTERVAL = 20.hours
    REQUEUE_AFTER = 10.minutes
    # Error prefix of an automatic extract run refused because a switch was off or unreadable (ManifestExtractJob):
    # it never reached the engine, so it is not an attempt.
    SWITCH_REFUSAL = 'automation_paused'
    REFUSED_REQUEUE_AFTER = 1.hour

    # What one pass queued (FIN event ids) and why rows were skipped (FIN id => reason Symbol).
    Plan = Data.define(:prepares, :extractions, :skipped) do
      def self.empty = new(prepares: [], extractions: [], skipped: {})
      def queued? = prepares.any? || extractions.any?
    end

    # A prepare request for a row.
    Request = Data.define(:mode, :up_to, :phases)

    # == Params
    # - season: the board season (default: SeasonBoard::Builder.latest_season);
    # - builder: object responding to #call with a Builder::Result (default: a Builder for the season);
    # - activity_log: SeasonBoard::ActivityLog;
    # - extract_preflight: callable returning nil (engine ready) or an error Symbol (default: the
    #   PdfManifests::BatchRunner preflight, as ManifestExtractJob runs it).
    def initialize(season: Builder.latest_season, builder: nil, activity_log: nil, extract_preflight: nil)
      @season = season
      @builder = builder
      @activity_log = activity_log || ActivityLog.new
      @extract_preflight = extract_preflight
    end

    # Returns the Plan of the pass (empty when the master switch is off or there is no season).
    def call
      return Plan.empty if @season.nil? || !DataFix::Automation.enabled?

      @skipped = {}
      rows = Snapshot.build!(@season, builder:).rows
      prepares = DataFix::Automation.enabled?(:auto_prepare) && pipeline_facts_readable? ? plan_prepares(rows) : []
      extractions = DataFix::Automation.enabled?(:auto_extract) ? plan_extractions(rows) : []
      Plan.new(prepares:, extractions:, skipped: @skipped)
    end

    # True when MAX_EXTRACT_ATTEMPTS automatic extractions of the PDF were unsuccessful (read by the "gave up" inbox
    # item too). An unreadable count gives up (fail closed).
    def self.extraction_gave_up?(pdf_path)
      count = unsuccessful_extractions(pdf_path)
      count.nil? || count >= MAX_EXTRACT_ATTEMPTS
    end

    # Number of unsuccessful automatic extraction runs of the PDF (by basename): every automatic run not ended 'done'
    # (failed, refused for any reason but a switch off, or queued/running and stale: orphaned by a restart or a killed
    # worker). Nil when unreadable.
    def self.unsuccessful_extractions(pdf_path, now: Time.current)
      Ops.safely(nil) do
        next nil unless Ops.available?

        runs = Ops::PipelineRun.where(kind: 'extract', subject_key: File.basename(pdf_path.to_s), origin: 'auto').where.not(status: 'done')
        runs.to_a.count { |run| run.pending? ? run.stale?(now:) : !switch_refusal?(run) }
      end
    end

    # A run refused because the automation switch was off or unreadable (never reached the engine).
    def self.switch_refusal?(run)
      run.status == 'refused' && run.error.to_s.start_with?("#{SWITCH_REFUSAL}:")
    end

    # The prepare request for a board row, or nil (public for the specs and the board).
    def prepare_request(row)
      pipeline = row.pipeline
      return skip(row, :held) if pipeline&.held?
      return skip(row, :recent_run) if recently_run?(pipeline)

      request = request_for(row, pipeline)
      return nil unless request
      return skip(row, :edited) if edited?(row, pipeline)

      request
    end

    private

    def builder
      @builder ||= Builder.new(season: @season, activity_log: @activity_log)
    end

    # False when the ops pipeline facts of the build could not be read (no prepare is queued in that pass).
    def pipeline_facts_readable?
      index = builder.respond_to?(:pipeline_index) ? builder.pipeline_index : nil
      return true unless index&.read_error?

      Rails.logger.warn('[SeasonBoard::PipelinePlanner] ops pipeline facts unreadable: no prepare queued in this pass')
      false
    end

    def skip(row, reason)
      @skipped[row.fin_event_id] = reason if @skipped && row.fin_event_id
      nil
    end

    # == Prepares

    def plan_prepares(rows)
      queued = []
      rows.each do |row|
        break if queued.size >= MAX_PREPARES_PER_PASS
        next if row.fin_event_id.blank? || row.busy?

        request = prepare_request(row)
        queued << row.fin_event_id if request && enqueue_prepare(row, request)
      end
      queued
    end

    def request_for(row, pipeline)
      case row.state
      when :results_ready then Request.new(mode: 'prepare', up_to: 5, phases: nil)
      when :structure_ready, :crawled_no_manifest then Request.new(mode: 'prepare', up_to: 1, phases: nil)
      when :needs_review, :ready_to_commit then review_request(pipeline)
      when :in_review then pipeline&.failed_but_changed? ? Request.new(mode: 'prepare', up_to: 5, phases: nil) : nil
      end
    end

    def review_request(pipeline)
      return nil unless pipeline
      return Request.new(mode: 'refresh_new_entities', up_to: 5, phases: nil) if pipeline.db_behind?
      return Request.new(mode: 'rebuild_stale', up_to: 5, phases: nil) if pipeline.stale_phases.any? || !pipeline.fresh?
      return Request.new(mode: 'rebuild_stale', up_to: 5, phases: [5]) if collision_cleared?(pipeline)

      nil
    end

    # A prepare run of the source ended (or was queued) less than REQUEUE_AFTER ago (REFUSED_REQUEUE_AFTER when
    # refused): the next pass decides (no loop on the same source).
    def recently_run?(pipeline)
      run = pipeline&.last_run
      return false unless run

      at = run.finished_at || run.updated_at || run.created_at
      window = run.status == 'refused' ? REFUSED_REQUEUE_AFTER : REQUEUE_AFTER
      at.present? && at > window.ago
    end

    # True when the phase files of the row's source hold operator edits (adopted pre-existing files included).
    # Read from the files themselves (the ops mirror can lag); an unreadable source counts as edited.
    def edited?(row, pipeline)
      return true if pipeline&.edited_recorded?

      source = PipelineIndex.active_source(row.disk_entry)
      return false if source.nil? || source.phase_paths.blank?

      files_edited?(source, pipeline&.source_path.presence || source.lt4_path || source.review_path)
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::PipelinePlanner] edit check failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      true
    end

    # True when the phase files at +path+ hold edits, or are not the ones the board found (named differently).
    def files_edited?(source, path)
      data_fix = DataFix::Pipeline.for(path, progress: Import::Progress::Null.new, actor: :auto)
      return true unless source.phase_paths.values.map(&:to_s).sort == present_phase_paths(data_fix)

      data_fix.any_edited?
    end

    def present_phase_paths(data_fix)
      DataFix::Pipeline::PHASES.map { |phase| data_fix.phase_path(phase).to_s }.select { |path| File.exist?(path) }.sort
    end

    # Phase 5 is blocked by import_key collisions whose other sources were committed after the verdict.
    def collision_cleared?(pipeline)
      bases = Array(pipeline.collision_bases)
      return false if bases.empty?

      Ops.safely(false) do
        verdict = Ops::PhaseVerdict.find_by(pipeline_source_id: pipeline.source_id, phase: 5)
        next false unless verdict&.checked_at

        Ops::CommitReport.where(source_base: bases, status: Ops::CommitReport::COMMITTED_STATUSES)
                         .exists?(['finished_at > ?', verdict.checked_at])
      end
    end

    def enqueue_prepare(row, request)
      Scheduler.prepare!(season_id: @season.id, source_path: row.next_action.params[:file_path], origin: :auto, fin_event_id: row.fin_event_id,
                         up_to: request.up_to, mode: request.mode, phases: request.phases).present?
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::PipelinePlanner] prepare enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      false
    end

    # == Extractions

    def plan_extractions(rows)
      candidates = rows.select { |row| extract_candidate?(row) }
      return [] if candidates.empty?

      error = preflight_error
      if error
        candidates.each { |row| skip(row, :engine_unavailable) }
        return []
      end

      candidates.first(MAX_EXTRACTIONS_PER_PASS).select { |row| enqueue_extract(row) }.map(&:fin_event_id)
    end

    def extract_candidate?(row)
      pdf_path = row.next_action&.params&.dig(:pdf_path)
      return false unless row.state == :manifest_pending && row.fin_event_id.present? && !row.busy? && pdf_path.present?

      reason = extract_skip_reason(row, pdf_path)
      skip(row, reason) if reason
      reason.nil?
    end

    def extract_skip_reason(row, pdf_path)
      if self.class.extraction_gave_up?(pdf_path) then :extraction_gave_up
      elsif recently_extracted?(row, pdf_path) then :recent_extraction
      end
    end

    # Last attempt (manual or automatic, ActivityLog) or automatic run of the PDF less than MIN_EXTRACT_INTERVAL ago.
    # Unreadable: true (fail closed).
    def recently_extracted?(row, pdf_path)
      last_logged = @activity_log.last_attempt_at(row.fin_event_id, :extract)
      last_run = Ops::PipelineRun.where(kind: 'extract', subject_key: File.basename(pdf_path.to_s)).maximum(:created_at)
      [last_logged, last_run].compact.any? { |time| time > MIN_EXTRACT_INTERVAL.ago }
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::PipelinePlanner] last extraction of #{File.basename(pdf_path.to_s)} unreadable: #{e.class}")
      true
    end

    # The engine preflight, once per pass (nil when ready).
    def preflight_error
      return @preflight_error if defined?(@preflight_error)

      @preflight_error = (@extract_preflight || default_preflight).call
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::PipelinePlanner] extraction preflight failed: #{e.class}: #{e.message}")
      @preflight_error = :engine_unavailable
    end

    def default_preflight
      -> { PdfManifests::BatchRunner.new(season_id: @season.id).preflight_error }
    end

    def enqueue_extract(row)
      Scheduler.extract!(season_id: @season.id, fin_event_id: row.fin_event_id, origin: :auto, pdf_path: row.next_action.params[:pdf_path])
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::PipelinePlanner] extract enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      false
    end
  end
end
