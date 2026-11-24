# frozen_string_literal: true

module Maintenance
  module SeasonStart
    #
    # = Maintenance::SeasonStart::Step
    #
    # One step of the season-start checklist (Maintenance::SeasonStart::Checklist), computed on every view:
    # - key, number (1-8), kind: :data (done read from the data), :operator (a tick box), :operation (an operation
    #   run, done read from the data), :remote (the on-demand remote check);
    # - done (bool), ready (every previous step done or skipped), item (Ops::SeasonChecklistItem or nil);
    # - facts (Array of texts), action (Symbol: :confirm, :upload, :check_remote, :operation, :repair or nil),
    #   operation (Hash 'key' / 'params' of the operation of an :operation or :repair action), last_run (Ops::OperationRun).
    #
    Step = Data.define(:key, :number, :kind, :done, :ready, :item, :facts, :action, :operation, :last_run) do
      def skipped? = !done && item&.skipped? == true
      def finished? = done || skipped?
      def ready? = ready
      def done? = done
      def from_data? = kind != :operator

      # 'done', 'skipped', 'blocked' (prerequisites not met) or 'pending'.
      def status
        return 'done' if done
        return 'skipped' if skipped?

        ready ? 'pending' : 'blocked'
      end

      def title = I18n.t("maintenance.season_start.steps.#{key}.title")
      def body = I18n.t("maintenance.season_start.steps.#{key}.body")

      # True for the tick-box steps the operator may skip.
      def skippable? = kind == :operator
    end
  end
end
