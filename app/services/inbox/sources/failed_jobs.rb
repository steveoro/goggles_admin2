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
    # - Solid Queue failed executions => "Discard" (POST dashboard#discard_failed_job), plus a secondary "Retry"
    #   (POST dashboard#retry_failed_job) only for the jobs outside PROTECTED_JOBS.
    #
    # Commit, push, maintenance-apply and restore jobs are never retried from here (never automatically, and not
    # by one click on the dashboard): they get "Discard" only (later phases add a link to their report).
    #
    class FailedJobs < Inbox::Source
      # Jobs offered "Discard" only (class names; they exist from phases 07, 09, 11 and 14 on).
      PROTECTED_JOBS = %w[DataFixCommitJob Outbox::PushJob Maintenance::RunJob RestoreJob].freeze

      # Board action kinds that a retry of each activity kind stands for.
      RETRY_KINDS = { crawl: %i[crawl check_results], extract: %i[extract_manifest] }.freeze
      # Action kind used when the board row is unknown (no board summary).
      DEFAULT_KINDS = { crawl: :crawl, extract: :extract_manifest }.freeze

      # True when a failed job of the class (String) may be retried from the dashboard.
      def self.retriable?(class_name)
        class_name.present? && PROTECTED_JOBS.exclude?(class_name.to_s)
      end

      def items(context)
        board_items(context) + queue_items(context)
      end

      private

      # == Season board activity

      def board_items(context)
        summary = board_summary(context)
        SeasonBoard::ActivityLog.new.all_entries.filter_map do |entry|
          next unless entry.failed? || entry.stale?(context.now)

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

      # Board action kind to retry, or nil when the row no longer needs it (or is busy, or gone).
      def retry_kind(entry, row, summary)
        return DEFAULT_KINDS[entry.kind] if summary.nil?
        return if row.nil? || row.busy?

        row_kind = row.next_action&.kind
        row_kind if RETRY_KINDS.fetch(entry.kind, []).include?(row_kind)
      end

      def board_item(entry, row, kind, summary, context)
        status = entry.failed? ? :failed : :stuck
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
