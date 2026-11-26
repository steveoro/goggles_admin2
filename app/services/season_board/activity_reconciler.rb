# frozen_string_literal: true

require 'json'

module SeasonBoard
  #
  # = SeasonBoard::ActivityReconciler
  #
  # Closes the SeasonBoard::ActivityLog entries left open by a job that could not close them itself (0.10.99), so a board
  # row never stays "queued" for the 12 hours of ActivityLog::QUEUED_STALE_AFTER (its buttons disabled, the row out of
  # the inbox). Run at the top of every PipelinePlannerJob pass, before the automation switch check: it queues nothing.
  #
  # == Rules (queued or running entries only; done / failed ones are never touched)
  # 1. A :prepare entry whose Ops::PipelineRun is finished is closed from the run: done / yielded => :done, failed /
  #    refused => :failed, with the run message. The run is the entry's +run_id+; an entry written before 0.10.99 (no run
  #    id) maps to the latest prepare run of the sources whose fin_event_id is the entry key, when that run was created at
  #    most RUN_MATCH_WINDOW before the entry was queued.
  # 2. A queued entry of any kind, older than GRACE, with no unfinished Solid Queue job of its class(es) (JOB_CLASSES)
  #    for its key, is closed as :failed with reason ActivityLog::LOST_REASON ("lost"); a prepare run of that entry
  #    still 'queued' is closed 'refused' with error 'lost' (so a Retry is not refused for 30 minutes). A job whose key
  #    cannot be read from its arguments counts as a match for every entry of its kind (nothing is closed).
  #
  # Each close is a compare-and-set (ActivityLog#finish_unchanged!): an entry that started or was queued again meanwhile
  # is left alone. Never raises: an unreadable ops DB skips rule 1, an unreadable (or non Solid Queue) queue skips rule 2.
  #
  class ActivityReconciler
    # Age of a queued entry before rule 2 looks for its job (the Scheduler writes the entry just before the enqueue).
    GRACE = 2.minutes
    # A legacy prepare entry (no run id) matches the latest run created at most this long before it was queued.
    RUN_MATCH_WINDOW = 1.minute
    # Job classes doing the work of each activity kind.
    JOB_CLASSES = {
      crawl: %w[MeetingCrawlJob SourceCrawlJob], extract: %w[ManifestExtractJob], prepare: %w[DataFixPrepareJob]
    }.freeze
    # Activity status of a finished prepare run.
    RUN_STATUSES = { 'done' => :done, 'yielded' => :done, 'failed' => :failed, 'refused' => :failed }.freeze
    # Key of a job whose arguments name no key (it matches every entry of its kind).
    ANY_KEY = :any

    # One entry closed: key (FIN id or 'src:' key), kind, status (:done / :failed), reason (nil or 'lost').
    Closed = Data.define(:key, :kind, :status, :reason)

    # == Params
    # - activity_log: SeasonBoard::ActivityLog;
    # - queue_probe: object answering #live_keys(class_names) with the Set of keys of the unfinished jobs of those
    #   classes (ANY_KEY for a job without a readable key), or nil when the queue cannot be read (default: QueueProbe);
    # - now: reference time.
    def initialize(activity_log: ActivityLog.new, queue_probe: QueueProbe.new, now: Time.current)
      @activity_log = activity_log
      @queue_probe = queue_probe
      @now = now
      @live_keys = {}
    end

    # Returns the Array of Closed entries (pinging the open pages when any). Never raises.
    def call
      open_entries = @activity_log.reload!.all_entries.select { |entry| entry.queued? || entry.running? }
      closed = open_entries.filter_map { |entry| reconcile(entry) }
      Notifier.ping if closed.any?
      closed
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::ActivityReconciler] skipped: #{e.class}: #{e.message}")
      []
    end

    private

    def reconcile(entry)
      (entry.kind == :prepare && close_from_run(entry)) || close_lost(entry)
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::ActivityReconciler] #{entry.kind} #{entry.fin_event_id}: #{e.class}: #{e.message}")
      nil
    end

    # == Rule 1: prepare entries of a finished run

    def close_from_run(entry)
      run = run_for(entry)
      status = run && RUN_STATUSES[run.status]
      return unless status

      close(entry, status, run.message.to_s.truncate(200), nil)
    end

    # The Ops::PipelineRun of a prepare entry (its run id, else the latest prepare run of the FIN id), or nil.
    def run_for(entry)
      Ops.safely do
        next unless Ops.available?
        next Ops::PipelineRun.find_by(id: entry.run_id, kind: 'prepare') if entry.run_id.present?

        legacy_run(entry)
      end
    end

    def legacy_run(entry)
      since = entry.queued_at || entry.started_at
      return if since.nil? || ActivityLog.source_key?(entry.fin_event_id)

      source_ids = Ops::PipelineSource.where(fin_event_id: entry.fin_event_id).select(:id)
      run = Ops::PipelineRun.where(pipeline_source_id: source_ids, kind: 'prepare').order(:id).last
      run if run && run.created_at >= since - RUN_MATCH_WINDOW
    end

    # == Rule 2: queued entries without a job

    def close_lost(entry)
      return unless queued_past_grace?(entry) && job_gone?(entry)

      closed = close(entry, :failed, I18n.t('season_board.activity.lost_message'), ActivityLog::LOST_REASON)
      refuse_lost_run(entry) if closed && entry.kind == :prepare
      closed
    end

    def queued_past_grace?(entry)
      entry.queued? && entry.queued_at.present? && entry.queued_at < @now - GRACE
    end

    # True when the queue could be read and holds no unfinished job of the entry's kind for its key.
    def job_gone?(entry)
      live = live_keys(entry.kind)
      !live.nil? && live.exclude?(ANY_KEY) && live.exclude?(entry.fin_event_id)
    end

    # Keys of the unfinished jobs of the kind's classes (read once per pass and kind), or nil.
    def live_keys(kind)
      return @live_keys[kind] if @live_keys.key?(kind)

      @live_keys[kind] = @queue_probe.live_keys(JOB_CLASSES.fetch(kind))
    end

    # The run of a lost prepare entry, still 'queued' (never started), is closed 'refused' (no planner loop: the planner
    # waits PipelinePlanner::REFUSED_REQUEUE_AFTER after a refused run).
    def refuse_lost_run(entry)
      return if entry.run_id.blank?

      Ops.safely do
        run = Ops::PipelineRun.find_by(id: entry.run_id, kind: 'prepare', status: 'queued') if Ops.available?
        run&.finish!(status: 'refused', error: "#{ActivityLog::LOST_REASON}: #{I18n.t('season_board.activity.lost_message')}")
      end
    end

    def close(entry, status, message, reason)
      saved = @activity_log.finish_unchanged!(entry, status:, message:, reason:)
      saved && Closed.new(key: entry.fin_event_id, kind: entry.kind, status:, reason:)
    end

    #
    # = SeasonBoard::ActivityReconciler::QueueProbe
    #
    # Keys of the unfinished Solid Queue jobs (finished_at NULL and no failed execution: ready, scheduled, blocked or
    # claimed) of some job classes, read from their serialized arguments: 'key' (SourceCrawlJob), 'fin_event_id', or the
    # source key of a ManifestExtractJob 'pdf_path' (as Sources::ManifestQueue logs it). Nil when Solid Queue is not the
    # Active Job adapter (the test environment) or its tables cannot be read.
    #
    class QueueProbe
      def live_keys(class_names)
        return nil unless Dashboard::QueueActivity.solid_queue?

        failed = SolidQueue::FailedExecution.select(:job_id)
        SolidQueue::Job.where(class_name: class_names, finished_at: nil).where.not(id: failed)
                       .pluck(:class_name, :arguments).to_set { |class_name, arguments| self.class.key_for(class_name, arguments) }
      rescue StandardError => e
        Rails.logger.warn("[SeasonBoard::ActivityReconciler] queue unreadable: #{e.class}: #{e.message}")
        nil
      end

      # Activity key of a job from its serialized arguments (the Active Job payload, a Hash or its JSON), or ANY_KEY.
      def self.key_for(class_name, arguments)
        args = job_arguments(arguments)
        return ANY_KEY unless args.is_a?(Hash)

        args['key'].presence || args['fin_event_id'].presence&.to_s || pdf_key(class_name, args['pdf_path']) || ANY_KEY
      end

      # The keyword arguments Hash of a serialized Active Job payload (or nil).
      def self.job_arguments(arguments)
        payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
        payload.is_a?(Hash) ? Array(payload['arguments']).first : nil
      rescue JSON::ParserError
        nil
      end

      # The 'src:' key of a Sources manifest extraction (Sources::ManifestQueue), or nil.
      def self.pdf_key(class_name, pdf_path)
        ActivityLog.source_key('extract', pdf_path.to_s) if class_name == 'ManifestExtractJob' && pdf_path.present?
      end
    end
  end
end
