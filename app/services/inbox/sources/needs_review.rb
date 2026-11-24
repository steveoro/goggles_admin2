# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::NeedsReview
    #
    # Board rows in :needs_review (a phase verdict asks for a decision, or the stored "ready" is no longer current) =>
    # "Review step N": opens that Data-Fix step with the review filter on.
    #
    class NeedsReview < PipelineRows
      STATE = :needs_review
      BAND = :review
      ACTION_KIND = :resume_review

      protected

      def item_action(row)
        target = board_target(row)
        target && action(I18n.t('inbox.needs_review.action', step: row.next_action.params[:phase]), target.path)
      end

      def unmatched_action(source, _summary)
        step = source.pipeline_detail[:step] || source.phase || 1
        action(I18n.t('inbox.needs_review.action', step:),
               SeasonBoard::ActionPaths.review_step_path(source.review_path, step, filter_state: 'review'))
      end
    end
  end
end
