# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Scheduler
  #
  # Single entry point for enqueuing the Season board background work (manual buttons,
  # CrawlPlanner, CalendarPlanner, PipelinePlanner & SeasonRecheckJob), so that every request is recorded as 'queued'
  # (ActivityLog, plus an Ops::PipelineRun row for the automatic extractions and every prepare) before
  # the job is enqueued and a second request for the same FIN id / source is refused while the first one
  # is still queued or running.
  #
  # .crawl! / .extract! return false (doing nothing) when the FIN id is already busy with the same
  # kind of work, true once the job has been enqueued (dropping the stored board summary, see
  # SeasonBoard::Snapshot, and pinging the open pages). .prepare! returns the queued Ops::PipelineRun,
  # or false when refused.
  # If the enqueue itself fails the log entry (and run row) is closed as failed and the error is re-raised.
  #
  # Nothing here enqueues a commit or a push (see spec/automation_boundary_spec.rb).
  #
  class Scheduler
    # Prepare modes of DataFixPrepareJob.
    PREPARE_MODES = %w[prepare rebuild_stale refresh_new_entities].freeze

    # Job priorities on the serial 'background' worker (lower first, 0.10.103): the operator's work goes first, the board
    # buttons (0, the jobs' default) then the Sources crawls and the "Extract next 20" batch (10); then the automatic
    # 'Eventi' calendar crawl (AUTO_CALENDAR_PRIORITY: the links it brings let the next planner pass crawl the meetings
    # without one) and last the automatic meeting crawls and manifest extractions (AUTO_PRIORITY). So a crawl the
    # operator asks for never waits behind the automatic queue, only behind the job running now.
    AUTO_CALENDAR_PRIORITY = 15
    AUTO_PRIORITY = 20

    # Enqueues a MeetingCrawlJob for the FIN results URL.
    # - origin: :manual (board button, priority 0) or :auto (watcher / daily re-check, AUTO_PRIORITY)
    def self.crawl!(season_id:, fin_event_id:, url:, origin:) # rubocop:disable Naming/PredicateMethod
      log = ActivityLog.new
      return false if log.busy?(fin_event_id, kind: :crawl)

      auto = origin.to_s == 'auto'
      record_and_enqueue(log, fin_event_id, season_id:, kind: :crawl, origin:, url:) do
        (auto ? MeetingCrawlJob.set(priority: AUTO_PRIORITY) : MeetingCrawlJob).perform_later(season_id:, fin_event_id: fin_event_id.to_s, url:, origin: origin.to_s)
      end
      true
    end

    # Enqueues a SourceCrawlJob of the season's default FIN 'Eventi' calendar (Sources::CrawlRequest.eventi_calendar:
    # the request of the crawler tab's FIN calendar form left on its defaults, same ActivityLog key, so a manual and an
    # automatic crawl never run twice). 0.10.103.
    # - origin: :auto (SeasonBoard::CalendarPlanner: after a FIN change, and the daily one) or :manual.
    # Returns false (doing nothing) while that crawl is queued or running or when the request is invalid (e.g. a season
    # unknown to the local DB), true once enqueued. The job refuses an automatic run with the 'auto_calendar' switch off.
    # Never names the 'calendar_results' kind (processing a whole calendar stays an operator click).
    def self.calendar_crawl!(season:, origin:) # rubocop:disable Naming/PredicateMethod
      request = Sources::CrawlRequest.eventi_calendar(season)
      return false unless request.valid?

      log = ActivityLog.new
      return false if log.busy?(request.key, kind: :crawl)

      auto = origin.to_s == 'auto'
      args = request.to_job_args.merge(key: request.key, label: request.label, origin: auto ? 'auto' : 'operator')
      record_and_enqueue(log, request.key, season_id: season.id, kind: :crawl, origin: auto ? :auto : :manual, url: request.target,
                                           label: request.label) do
        (auto ? SourceCrawlJob.set(priority: AUTO_CALENDAR_PRIORITY) : SourceCrawlJob).perform_later(**args)
      end
      true
    end

    # Enqueues a ManifestExtractJob for the pending manifest PDF of the FIN id.
    # - engine: LLM engine name (nil for the default, see PdfManifests::ClientFactory)
    # - origin: :manual (board button, the default) or :auto (PipelinePlanner): an automatic attempt also writes an
    #   Ops::PipelineRun (kind 'extract', subject_key: the PDF basename), counted by the planner's retry cap;
    #   it is refused without the ops DB.
    # - pdf_path: the pending PDF (required for :auto, to key the run row; when given, a Sources extraction of the
    #   same PDF, logged under its 'src:' key, also refuses the request);
    # - priority: optional job priority (phase 15: the Sources "Extract next 20" batch uses 10; an automatic extraction
    #   defaults to AUTO_PRIORITY, 0.10.103).
    # rubocop:disable-next Naming/PredicateMethod, Metrics/ParameterLists
    def self.extract!(season_id:, fin_event_id:, engine: nil, origin: :manual, pdf_path: nil, priority: nil)
      log = ActivityLog.new
      return false if log.busy?(fin_event_id, kind: :extract) || source_extraction_busy?(log, pdf_path)

      run = nil
      if origin.to_s == 'auto'
        priority ||= AUTO_PRIORITY
        run = create_run(kind: 'extract', subject_key: File.basename(pdf_path.to_s), origin: 'auto', message: pdf_path.to_s)
        return false unless run
      end

      record_and_enqueue(log, fin_event_id, season_id:, kind: :extract, origin:, run:) do
        args = { season_id:, fin_event_id: fin_event_id.to_s, engine: }
        args[:run_id] = run.id if run
        (priority ? ManifestExtractJob.set(priority:) : ManifestExtractJob).perform_later(**args)
      end
      true
    end

    # True when a Sources extraction of +pdf_path+ (ActivityLog key 'src:<sha1>' of its real path) is queued or running.
    def self.source_extraction_busy?(log, pdf_path)
      return false if pdf_path.blank?

      real = File.exist?(pdf_path.to_s) ? File.realpath(pdf_path.to_s) : pdf_path.to_s
      log.busy?(ActivityLog.source_key('extract', real), kind: :extract)
    end
    private_class_method :source_extraction_busy?

    # Enqueues a DataFixPrepareJob for the source (phases 1..up_to, never a commit), passing it the FIN id so that the job
    # closes the activity entry itself, whatever the way it ends (0.10.99).
    # Refused (false) without the ops DB, while the source lease is held or a prepare run of the source is queued or
    # running, while a commit of the source is pending, and while the FIN id has a busy :prepare log entry.
    # - source_path: the source to prepare (LT2, LT4 or phase file: the job resolves the canonical working copy);
    # - origin: :auto (planner) or :operator (board button);
    # - mode: 'prepare' | 'rebuild_stale' | 'refresh_new_entities'; phases: optional subset (e.g. [5]).
    # Returns the Ops::PipelineRun (status 'queued') or false.
    # rubocop:disable-next Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.prepare!(season_id:, source_path:, origin:, fin_event_id: nil, up_to: 5, mode: 'prepare', phases: nil)
      raise ArgumentError, "unknown prepare mode #{mode.inspect}" unless PREPARE_MODES.include?(mode.to_s)

      origin = origin.to_s == 'auto' ? 'auto' : 'operator'
      log = ActivityLog.new
      return false if fin_event_id.present? && log.busy?(fin_event_id, kind: :prepare)

      source = prepare_target(source_path, season_id)
      run = source && create_run(kind: 'prepare', subject_key: source.base, origin:, source:, message: mode.to_s)
      return false unless run

      job_args = { source_path: source_path.to_s, season_id:, origin:, up_to: up_to.to_i, mode: mode.to_s, phases: phases&.map(&:to_i),
                   fin_event_id: fin_event_id.presence&.to_s }
      record_and_enqueue(log, fin_event_id.presence, season_id:, kind: :prepare, origin: origin == 'auto' ? :auto : :manual, run:) do
        enqueue_prepare(run, job_args)
      end
      run
    end

    def self.enqueue_prepare(run, job_args)
      job = DataFixPrepareJob.perform_later(**job_args, run_id: run.id)
      Ops.safely { run.update_columns(job_id: job.job_id) if job.respond_to?(:job_id) } # rubocop:disable Rails/SkipsModelValidations
    end
    private_class_method :enqueue_prepare

    # True when a prepare (or another build) of the source is queued, running or holding the lease.
    def self.prepare_busy?(source)
      return false unless source

      Ops.safely(true) do
        leased = source.lease_owner.present? && source.lease_expires_at.present? && source.lease_expires_at > Time.current
        leased || pending_runs(source, 'prepare').any? || Ops::CommitReport.pending.for_base(source.base).exists?
      end
    end

    # Pending (queued/running) and not stale runs of +kind+ for the source.
    def self.pending_runs(source, kind)
      Ops::PipelineRun.pending.where(pipeline_source_id: source.id, kind:).to_a.reject(&:stale?)
    end

    # The Ops::PipelineSource row of +source_path+, or nil when the prepare must be refused (no ops DB, busy).
    def self.prepare_target(source_path, season_id)
      Ops.safely do
        next unless Ops.available?

        folder_season = Ops::PipelineSource.season_id_for(source_path)
        source = Ops::PipelineSource.for_path!(source_path, season_id: folder_season.positive? ? folder_season : season_id)
        prepare_busy?(source) ? nil : source
      end
    end
    private_class_method :prepare_target

    def self.create_run(kind:, subject_key:, origin:, source: nil, message: nil)
      Ops.safely do
        next unless Ops.available?

        Ops::PipelineRun.create!(pipeline_source: source, subject_key:, kind:, origin:, status: 'queued', message: message.to_s.truncate(250))
      end
    end
    private_class_method :create_run

    # (a prepare entry keeps the id of its run: SeasonBoard::ActivityReconciler closes it from the run when the job could not)
    # (+label+: shown instead of the key by the activity strip, for a Sources key such as the calendar crawl's)
    def self.record_and_enqueue(log, fin_event_id, season_id:, kind:, origin:, url: nil, run: nil, label: nil) # rubocop:disable Metrics/ParameterLists
      log.queue!(fin_event_id, kind:, origin:, url:, label:, run_id: (run.id if kind == :prepare && run)) if fin_event_id
      begin
        yield
      rescue StandardError => e
        message = "enqueue failed: #{e.message}".truncate(200)
        log.finish!(fin_event_id, kind:, status: :failed, message:) if fin_event_id
        Ops.safely { run&.finish!(status: 'failed', error: message) }
        raise
      end
      Snapshot.invalidate!(season_id)
      Notifier.ping
      nil
    end
    private_class_method :record_and_enqueue
  end
end
