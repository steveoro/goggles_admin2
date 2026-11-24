# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::PrepareFailed
    #
    # Board rows in :prepare_failed (the last Data-Fix prepare failed, source unchanged since) => "Retry": a POST of the
    # FIN event id to season_board/prepare (DataFixPrepareJob, operator origin; never a commit).
    #
    class PrepareFailed < PipelineRows
      STATE = :prepare_failed
      BAND = :failed
      ACTION_KIND = :prepare

      protected

      def item_action(row)
        target = board_target(row)
        target&.post? && action(I18n.t('season_board.actions.prepare'), target.path, http_method: :post, params: target.params)
      end

      # (a POST to the Sources "Prepare" of the source: DataFixPrepareJob, operator origin; never a commit)
      def unmatched_action(source, summary)
        action(I18n.t('season_board.actions.prepare'), url_helpers.sources_prepare_path, http_method: :post,
                                                                                         params: { path: source.review_path, season_id: summary.season_id })
      end
    end
  end
end
