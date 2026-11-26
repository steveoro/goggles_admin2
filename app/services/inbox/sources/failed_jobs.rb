# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::FailedJobs
    #
    # Failed or stuck background work:
    # - Season board crawls & manifest extractions (SeasonBoard::ActivityLog) whose latest attempt failed or is
    #   stale (stuck), while the board row still asks for that action => "Retry": a POST to the same board action
    #   (SeasonBoard::ActionPaths), keyed like the BoardRows item it replaces ('board:<fin_event_id>:<kind>');
    # - Season board prepares (0.10.99) whose latest attempt is stuck (stale) or was closed as lost by
    #   SeasonBoard::ActivityReconciler (its job was no longer in the queue), on a row whose next action names its
    #   source => "Retry": a POST to season_board/prepare, keyed 'board:<fin_event_id>:prepare' like the PrepareFailed
    #   item (a :prepare_failed row is left to that source; any other failed prepare is a refusal or a failure the row
    #   state already shows);
    # - Solid Queue failed executions => "Discard" (POST dashboard#discard_failed_job), plus a secondary "Retry"
    #   (POST dashboard#retry_failed_job) only for the jobs outside PROTECTED_JOBS;
    # - (0.10.103) the failed AUTOMATIC crawl of the board season's FIN 'Eventi' calendar (its latest attempt: a later
    #   crawl, successful or manual, replaces it; a refusal because the automation was off is no failure) => "Retry": an
    #   operator POST of the same crawl (Sources::CrawlsController, the crawler tab's 'Eventi' defaults), keyed
    #   'calendar_crawl:<season_id>'.
    #
    # Commit, push, maintenance-apply and restore jobs are never retried from here (never automatically, and not
    # by one click on the dashboard): they get "Discard" only (later phases add a link to their report).
    #
    class FailedJobs < Inbox::Source
      # Jobs offered "Discard" only (class names; they exist from phases 07, 09, 11 and 14 on).
      PROTECTED_JOBS = %w[DataFixCommitJob Outbox::PushJob Maintenance::RunJob RestoreJob].freeze

      # Board action kinds that a retry of each activity kind stands for (a prepare is retried with the board :prepare
      # action on any row whose next action names a source: see #prepare_retry_kind).
      RETRY_KINDS = { crawl: %i[crawl check_results], extract: %i[extract_manifest], prepare: %i[prepare] }.freeze
      # Action kind used when the board row is unknown (no board summary).
      DEFAULT_KINDS = { crawl: :crawl, extract: :extract_manifest, prepare: :prepare }.freeze

      # True when a failed job of the class (String) may be retried from the dashboard.
      def self.retriable?(class_name)
        class_name.present? && PROTECTED_JOBS.exclude?(class_name.to_s)
      end

      def items(context)
        board_items(context) + calendar_items(context) + queue_items(context)
      end

      private

      # == The automatic 'Eventi' calendar crawl

      def calendar_items(context)
        season = context.season
        return [] unless season

        request = ::Sources::CrawlRequest.eventi_calendar(season)
        entry = SeasonBoard::ActivityLog.new.entry(request.key, :crawl)
        return [] unless entry&.failed? && entry.origin == :auto && !paused_refusal?(entry.message)

        [calendar_item(request, entry, context)]
      end

      def calendar_item(request, entry, context)
        item(
          key: "calendar_crawl:#{request.season_id}", kind: :calendar_crawl_failed, band: :failed, title: t('calendar.failed', label: request.label),
          detail: [short_time(entry.last_timestamp), entry.message.to_s.truncate(160)].compact_blank.join(' · '),
          subject: { season_id: request.season_id }, since: entry.last_timestamp || context.now,
          action: action(t(:retry), url_helpers.sources_crawls_path, http_method: :post, params: request.to_job_args)
        )
      end

      # A refusal because the automation switch was off (any locale of the message): no failure.
      def paused_refusal?(message)
        I18n.available_locales.any? { |locale| message.to_s == I18n.t('pipeline_automation.reasons.automation_paused', locale:) }
      end

      # == Season board activity

      def board_items(context)
        summary = board_summary(context)
        SeasonBoard::ActivityLog.new.all_entries.filter_map do |entry|
          # (a Sources crawl or extraction is no board row: its end is a toast and an event, phase 15)
          next if entry.source?
          next unless reported?(entry, context.now)

          row = summary&.row_for(entry.fin_event_id)
          kind = retry_kind(entry, row, summary)
          board_item(entry, row, kind, summary, context) if kind
        end
      end

      # The board summary, or nil (no season, or a failed fetch: BoardRows reports that one).
      def board_summary(context)
        context.board_snapshot
      rescue StandardError
        nil
      end

      # A failed or stuck crawl / extraction; a stuck or lost prepare (the other failed prepares are refusals, or failures
      # shown by the row state and Inbox::Sources::PrepareFailed).
      def reported?(entry, now)
        return entry.stale?(now) || entry.lost? if entry.kind == :prepare

        entry.failed? || entry.stale?(now)
      end

      # Board action kind to retry, or nil when the row no longer needs it (or is busy, or gone).
      def retry_kind(entry, row, summary)
        return DEFAULT_KINDS[entry.kind] if summary.nil?
        return if row.nil? || row.busy?
        return prepare_retry_kind(row) if entry.kind == :prepare

        row_kind = row.next_action&.kind
        row_kind if RETRY_KINDS.fetch(entry.kind, []).include?(row_kind)
      end

      # :prepare when the row's next action names its source (season_board/prepare reads it from there), except on a
      # :prepare_failed row (Inbox::Sources::PrepareFailed shows it, under the same key).
      def prepare_retry_kind(row)
        return if row.state == :prepare_failed || row.next_action&.params&.dig(:file_path).blank?

        RETRY_KINDS[:prepare].first
      end

      def board_item(entry, row, kind, summary, context)
        status = if entry.lost? then :lost
                 elsif entry.failed? then :failed
                 else :stuck
                 end
        item(
          key: "board:#{entry.fin_event_id}:#{kind}", kind: :"#{entry.kind}_#{status}", band: :failed,
          title: t("board.#{entry.kind}_#{status}", name: row&.name.presence || "FIN ##{entry.fin_event_id}"),
          detail: [short_time(entry.last_timestamp), entry.message.to_s.truncate(160)].compact_blank.join(' · '),
          subject: { fin_event_id: entry.fin_event_id, season_id: summary&.season_id }.compact,
          action: board_retry_action(entry, kind), since: entry.last_timestamp || context.now
        )
      end

      # "Retry": a POST of the FIN event id to the board action of that kind.
      def board_retry_action(entry, kind)
        target = SeasonBoard::ActionPaths.target_for(SeasonBoard::NextAction.new(kind:, params: { fin_event_id: entry.fin_event_id }))
        action(t(:retry), target.path, http_method: target.http_method, params: target.params)
      end

      # == Solid Queue failed executions

      def queue_items(context)
        Dashboard::QueueActivity.new.failed.map { |failed| queue_item(failed, context) }
      end

      def queue_item(failed, context)
        item(
          key: "job:#{failed.id}", kind: :job_failed, band: :failed, title: t(:job_title, job: failed.class_name || '?'),
          detail: job_detail(failed), subject: { job_id: failed.job_id, class_name: failed.class_name }.compact,
          action: action(t(:discard), url_helpers.dashboard_discard_failed_job_path, http_method: :post, params: { id: failed.id },
                                                                                     confirm: t(:discard_confirm, job: failed.class_name || '?')),
          secondary_action: retry_action(failed), since: failed.created_at || context.now
        )
      end

      def job_detail(failed)
        error = [failed.exception_class, failed.message].compact_blank.join(': ').truncate(200)
        [failed.queue_name, error].compact_blank.join(' · ')
      end

      # "Retry" for the jobs outside PROTECTED_JOBS (nil otherwise).
      def retry_action(failed)
        return unless self.class.retriable?(failed.class_name)

        action(t(:retry), url_helpers.dashboard_retry_failed_job_path, http_method: :post, params: { id: failed.id })
      end
    end
  end
end
