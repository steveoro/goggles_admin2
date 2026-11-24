# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::Base
    #
    # Parent of the rake task adapters: #call is the former task body (same texts, prompts and exits) speaking through
    # the Maintenance::RakeRunner (terminal, options, operation runs).
    #
    class Base
      attr_reader :runner

      delegate :env, :say, :write, :stop!, :confirm?, :simulate?, :force?, :flag, :file_index, :script_output_dir,
               :preview, :script_only, :apply, :write_script, :inspect_plan, :report_script!, :data_root, to: :runner

      def initialize(runner)
        @runner = runner
      end

      def call = raise(NotImplementedError, "#{self.class.name}#call")

      protected

      # The operation of a run (the instance that planned: its strategy is still there).
      def operation_of(executor) = executor.operation

      # Re-raises the error a strategy raised while planning (the former body did not rescue it: "rake aborted!").
      def raise_plan_exception!(operation)
        error = operation&.plan_exception
        raise(RakeRunner::TaskError, error.message, cause: nil) if error
      end

      # The plan errors of an inspector or a dry run that stopped on its own input checks.
      def plan_errors!(plan)
        return unless plan.blocked?

        say(plan.errors)
        stop!(1)
      end
    end
  end
end
