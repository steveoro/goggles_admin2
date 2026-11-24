# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::PipelineRows
    #
    # Common parent of the phase 10 inbox sources reading the Season board rows of one pipeline state from the stored
    # board summary (SeasonBoard::Snapshot): ReadyToCommit, NeedsReview, PrepareFailed. Subclasses define STATE,
    # BAND, ACTION_KIND (the item key suffix) and #item_action(row). The item title is the meeting name with the state
    # label (SeasonBoard::StateText), the detail its date and place; +subject[:file_path]+ is the row's source, so a
    # Data-Fix session item about the same file is de-duplicated (these sources are board sources, see
    # Inbox::Builder::BOARD_SOURCES). Busy rows (a prepare queued or running) are skipped.
    #
    # Key: 'board:<fin_event_id>:<ACTION_KIND>'.
    #
    class PipelineRows < Inbox::Source
      STATE = nil
      BAND = :review
      ACTION_KIND = nil

      def self.more_path
        Rails.application.routes.url_helpers.season_board_path(state: self::STATE)
      end

      def items(context)
        summary = context.board_snapshot
        return [] unless summary

        summary.rows_in(self.class::STATE).filter_map { |row| item_for(row, summary, context) }
      end

      protected

      # The Inbox::Action of the row (subclasses).
      def item_action(_row)
        raise NotImplementedError
      end

      private

      def item_for(row, summary, context)
        return if row.busy? || row.fin_event_id.blank? || row.next_action.nil?

        primary = item_action(row)
        return unless primary

        item(
          key: "board:#{row.fin_event_id}:#{self.class::ACTION_KIND}", kind: self.class::STATE, band: self.class::BAND,
          title: title_for(row), detail: detail_for(row), subject: subject_for(row, summary), action: primary,
          since: since_for(row, summary, context)
        )
      end

      def title_for(row)
        I18n.t('inbox.pipeline_rows.title', name: row.name, state: SeasonBoard::StateText.label(row.state, row.state_detail))
      end

      def detail_for(row)
        [[row.date_text, row.year].compact_blank.join(' '), row.place].compact_blank.join(' · ')
      end

      def subject_for(row, summary)
        { fin_event_id: row.fin_event_id, file_path: row.next_action.params[:file_path], season_id: summary.season_id }.compact
      end

      # The meeting date (older meetings first), else the board build time.
      def since_for(row, summary, context)
        date = row.last_date || row.first_date
        return date.in_time_zone if date

        summary.built_at || context.now
      end

      def board_target(row)
        SeasonBoard::ActionPaths.target_for(row.next_action)
      end
    end
  end
end
