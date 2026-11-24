# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::ReadyToCommit
    #
    # Board rows in :ready_to_commit (every phase verdict clean and fresh, prepared unattended or by hand) =>
    # "Commit": opens the commit summary (GET data_fix/commit_summary). The commit itself stays the operator's click
    # on that page, then Push in the Outbox: this source never commits anything.
    #
    class ReadyToCommit < PipelineRows
      STATE = :ready_to_commit
      BAND = :review
      ACTION_KIND = :commit

      protected

      def item_action(row)
        target = board_target(row)
        target && action(I18n.t('season_board.actions.commit'), target.path)
      end
    end
  end
end
