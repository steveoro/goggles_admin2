# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::ExtractionGaveUp
    #
    # Board rows still in :manifest_pending whose PDF failed SeasonBoard::PipelinePlanner::MAX_EXTRACT_ATTEMPTS
    # automatic extractions (Ops::PipelineRun kind 'extract'): the planner stopped trying => "Extract manually" (a POST
    # of the FIN event id to season_board/extract, as the board button). Same key as the board row's own
    # "Extract manifest" item (Inbox::Sources::BoardRows), in a more urgent band: this item replaces it.
    #
    # Key: 'board:<fin_event_id>:extract_manifest'.
    #
    class ExtractionGaveUp < Inbox::Source
      def self.more_path
        Rails.application.routes.url_helpers.season_board_path(state: :manifest_pending)
      end

      def self.enabled?(context)
        context.ops_available?
      end

      def items(context)
        summary = context.board_snapshot
        return [] unless summary

        summary.rows_in(:manifest_pending).filter_map { |row| item_for(row, summary, context) }
      end

      private

      def item_for(row, summary, context)
        pdf_path = gave_up_pdf(row)
        target = pdf_path && SeasonBoard::ActionPaths.target_for(row.next_action)
        return unless target&.post?

        item(
          key: "board:#{row.fin_event_id}:extract_manifest", kind: :extraction_gave_up, band: :failed,
          title: t(:title, name: row.name, count: SeasonBoard::PipelinePlanner::MAX_EXTRACT_ATTEMPTS),
          detail: t(:detail, pdf: File.basename(pdf_path)),
          subject: { fin_event_id: row.fin_event_id, season_id: summary.season_id },
          action: action(t(:action), target.path, http_method: :post, params: target.params),
          since: last_attempt_at(pdf_path) || summary.built_at || context.now
        )
      end

      # The pending PDF of a row whose automatic extractions gave up (nil otherwise).
      def gave_up_pdf(row)
        pdf_path = row.next_action&.params&.dig(:pdf_path)
        return if row.busy? || pdf_path.blank?

        pdf_path if SeasonBoard::PipelinePlanner.extraction_gave_up?(pdf_path)
      end

      def last_attempt_at(pdf_path)
        Ops.safely { Ops::PipelineRun.where(kind: 'extract', subject_key: File.basename(pdf_path)).maximum(:finished_at) }
      end
    end
  end
end
