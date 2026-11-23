# frozen_string_literal: true

# Helpers for the Phase 6 commit request specs (phase 09): the Commit click queues DataFixCommitJob, performed inline
# here, and the outcome is the Ops::CommitReport row (no session report any more).
module DataFixCommitHelpers
  # Guards result letting the commit through (the drift gate of phase 08 has no stored check in the test DB, so it
  # would ask for the acknowledgement; DataFix::Guards has its own specs with a fake gate).
  def allow_commit_guards
    allow(DataFix::Guards).to receive(:check)
      .and_return(DataFix::Guards::Result.new(level: :ok, reasons: [], verdict: nil, acknowledged: false))
  end

  # POST commit_phase6 + the queued DataFixCommitJob performed inline.
  def commit!(path, **params)
    allow_commit_guards
    perform_enqueued_jobs(only: DataFixCommitJob) { post commit_phase6_path(file_path: path), params: }
  end

  def last_report
    Ops::CommitReport.order(:id).last
  end
end

RSpec.configure do |config|
  config.include(ActiveJob::TestHelper, :data_fix_commit)
  config.include(DataFixCommitHelpers, :data_fix_commit)
end
