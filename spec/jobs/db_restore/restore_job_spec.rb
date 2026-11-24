# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::RestoreJob do
  after(:each) { Ops::Database.reset_state! }

  it 'runs on the maintenance worker, with no retry or discard handler' do
    expect(described_class.new.queue_name).to eq('maintenance')
    expect(described_class.rescue_handlers).to be_empty
    expect(DbRestore::InspectJob.rescue_handlers).to be_empty
    expect(DbRestore::SnapshotJob.rescue_handlers).to be_empty
    expect([DbRestore::InspectJob, DbRestore::SnapshotJob].map { |job| job.new.queue_name }).to all(eq('maintenance'))
  end

  it "shares the 'local_db_writer' concurrency key (group 'local_db_writer') with the other local DB writers" do
    job = described_class.new(run_id: 1, mode: 'load')
    expect(job.concurrency_key).to eq('local_db_writer/local_db_writer')
    expect(job.concurrency_key).to eq(DataFixCommitJob.new(commit_report_id: 9).concurrency_key)
    expect(described_class.concurrency_limit).to eq(1)
  end

  it 'hands the run to DbRestore::Restorer (and never raises)' do
    run = create_restore_run(status: 'confirmed')
    restorer = instance_double(DbRestore::Restorer)
    allow(DbRestore::Restorer).to receive(:new).and_return(restorer)
    allow(restorer).to receive(:call).and_raise('boom')
    expect { described_class.perform_now(run_id: run.id, mode: 'load') }.not_to raise_error
    expect(DbRestore::Restorer).to have_received(:new).with(run:, mode: 'load', job_id: anything)
  end

  # Invariant: enqueued only by an operator click in DbRestoreController (confirm, resume, load snapshot,
  # post-steps), through one private method; nothing else invokes it.
  it 'is invoked only by DbRestoreController, in one place' do
    invocation = /DbRestore::RestoreJob\s*\.\s*(perform_later|perform_now|perform|set|new)\b/
    invoking = Rails.root.glob('{app,lib,config}/**/*.{rb,haml,erb,rake,yml}').select do |path|
      path.readlines.any? { |line| !line.strip.start_with?('#') && line.match?(invocation) }
    end
    expect(invoking.map { |path| path.relative_path_from(Rails.root).to_s }).to eq(['app/controllers/db_restore_controller.rb'])
    source = Rails.root.join('app/controllers/db_restore_controller.rb').read
    expect(source.scan('DbRestore::RestoreJob.perform_later').size).to eq(1)
    expect(source.scan('DbRestore::SnapshotJob.perform_later').size).to eq(1)
  end
end
