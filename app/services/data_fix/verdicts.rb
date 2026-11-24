# frozen_string_literal: true

module DataFix
  #
  # = DataFix::Verdicts
  #
  # One checker per Data-Fix phase (Verdicts::Phase1 .. Phase5), each returning a DataFix::Verdict for a
  # DataFix::Pipeline. Checkers only READ: the phase files, the source file, the staging rows and the local DB.
  # 'blocked' issues are grounded in what makes the Phase 6 commit fail; 'review' issues need an operator decision
  # (see DataFix::ReviewRules).
  #
  module Verdicts
    module_function

    def for(phase)
      const_get("Phase#{Integer(phase)}")
    end
  end
end
