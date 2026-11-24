# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::BoardRows
    #
    # One item per Season board row with a next action (from the stored board summary, SeasonBoard::Snapshot),
    # skipping the busy rows (a crawl/extraction/prepare queued or running), the :push actions (PendingSql groups them)
    # and the rows in the pipeline states (:prepare_failed, :needs_review, :ready_to_commit: phase 10, owned by the
    # PrepareFailed, NeedsReview and ReadyToCommit sources).
    # The action target comes from SeasonBoard::ActionPaths: the review steps are links, crawl / check results /
    # extract manifest are POSTs of the FIN event id to the board, :link opens the board on the row.
    #
    # Key: 'board:<fin_event_id>:<action kind>'.
    #
    class BoardRows < Inbox::Source
      # Action kinds => band.
      BANDS = {
        resume_review: :review, review_results: :review, review_structure: :review, review_header: :review,
        extract_manifest: :acquire, check_results: :acquire, crawl: :acquire, link: :acquire
      }.freeze

      # Action kinds never emitted (they come from other sources).
      SKIPPED_KINDS = %i[push prepare commit].freeze

      # Row states never emitted (phase 10: their own sources).
      SKIPPED_STATES = SeasonBoard::StateResolver::PIPELINE_STATES

      def self.more_path
        Rails.application.routes.url_helpers.season_board_path
      end

      def items(context)
        summary = context.board_snapshot
        return [] unless summary

        summary.rows.filter_map { |row| item_for(row, summary, context) }
      end

      private

      def item_for(row, summary, context)
        kind = row.next_action&.kind
        return if kind.nil? || SKIPPED_KINDS.include?(kind) || !BANDS.key?(kind) || row.busy? || SKIPPED_STATES.include?(row.state)

        target = SeasonBoard::ActionPaths.target_for(row.next_action)
        return unless target

        label = action_label(row)
        item(
          key: "board:#{row.fin_event_id}:#{kind}", kind:, band: BANDS.fetch(kind), title: "#{label}: #{row.name}",
          detail: detail_for(row), subject: subject_for(row, summary),
          action: action(label, target.path, http_method: target.http_method, params: target.params),
          since: since_for(row, summary, context)
        )
      end

      # The board's own button label for the row action (e.g. "Resume step 3").
      def action_label(row)
        I18n.t("season_board.actions.#{row.next_action.kind}", phase: row.next_action.params[:phase])
      end

      def subject_for(row, summary)
        { fin_event_id: row.fin_event_id, file_path: row.next_action.params[:file_path], season_id: summary.season_id }.compact
      end

      def detail_for(row)
        state = I18n.t("season_board.states.#{row.state}", phase: row.state_detail[:phase])
        [[row.date_text, row.year].compact_blank.join(' '), row.place, state].compact_blank.join(' · ')
      end

      # The meeting date (older meetings first), else the board build time.
      def since_for(row, summary, context)
        date = row.last_date || row.first_date
        return date.in_time_zone if date

        summary.built_at || context.now
      end
    end
  end
end
