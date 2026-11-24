# frozen_string_literal: true

require 'rails_helper'

# Orchestration of DbRestore::RestoreJob with the load and the post-steps stubbed (no MySQL client, no drop).
RSpec.describe DbRestore::Restorer do
  let(:queues) { DbRestoreHelpers::FakeQueues.new }
  let(:target) { passing_target }
  let(:loader) { instance_double(DbRestore::Loader, call: true) }
  let(:post_steps) { instance_double(DbRestore::PostSteps, call: true) }
  let(:run) { lock_with_run(status: 'confirmed', user_id: 1) }

  before(:each) do
    allow(DbRestore::Preserver).to receive(:capture!) { |given| given.update!(preserved: given.preserved.merge('captured_at' => 'now')) }
    allow(DataFix::SessionIndex).to receive(:new).and_return(empty_session_index)
  end

  after(:each) { Ops::Database.reset_state! }

  def restorer(mode, job_id: 'job-1', **options)
    described_class.new(run:, mode:, job_id:, target:, queues:, loader:, post_steps:, drain_timeout: 0, poll_every: 0, **options)
  end

  it 'pauses the queues, captures, loads the dump and runs the post-steps' do
    expect(restorer('load').call).to be(true)
    expect(queues.paused).to eq(DbRestore::PAUSED_QUEUES)
    expect(DbRestore::Preserver).to have_received(:capture!).with(run)
    expect(loader).to have_received(:call).with(run.dump_path)
    expect(post_steps).to have_received(:call)
    expect(run.reload).to have_attributes(status: 'loading', job_id: 'job-1')
    expect(run.preserved['paused_queues']).to eq(DbRestore::PAUSED_QUEUES)
    expect(run.outcome['loaded_from']).to eq('dump')
  end

  it 'claims the run once (a duplicate perform does nothing)' do
    restorer('load').call
    expect(restorer('load').call).to be(false)
    expect(loader).to have_received(:call).once
  end

  it 'fails before the drop when the running jobs do not finish, releasing the lock and resuming the queues' do
    queues.claimed_jobs = [claimed_job('MeetingCrawlJob', 'background')]
    restorer('load').call
    expect(loader).not_to have_received(:call)
    expect(run.reload).to have_attributes(status: 'failed')
    expect(run.error).to include('MeetingCrawlJob')
    expect(queues.resumed).to eq(DbRestore::PAUSED_QUEUES)
    expect(queues.resumed_while_locked).to eq([false])
    expect(DbRestore::Lock.active?).to be(false)
    expect(Ops::Event.where(kind: 'db_restore.failed').count).to eq(1)
  end

  it 'never stores, logs or shows the API token found in an error' do
    token = GogglesDb::JWTManager.encode({ user_id: 1 }, 'spec-key')
    run.update!(preserved: run.preserved.merge('jwt' => token))
    allow(DbRestore::Preserver).to receive(:capture!).and_return({})
    allow(loader).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "Mysql2::Error: UPDATE users SET jwt = '#{token}'")
    allow(Rails.logger).to receive(:error).and_call_original
    restorer('load').call
    expect(run.reload).to be_interrupted
    expect([run.error, run.log, Ops::Event.last.data.to_json].join).not_to include(token)
    expect(run.error).to include('[FILTERED]')
    expect(Rails.logger).not_to have_received(:error).with(a_string_including(token))
  end

  it 'leaves the run interrupted (lock held) when the load fails mid-way, and a resume completes it' do
    allow(loader).to receive(:call).and_raise(DbRestore::CommandFailed, 'mariadb exited with status 1: ERROR 2013 (HY000): Lost connection')
    restorer('load').call
    expect(run.reload).to have_attributes(status: 'interrupted')
    expect(run.error).to include('Lost connection')
    expect(DbRestore::Lock.current_run).to eq(run)
    expect(queues.resumed).to be_empty

    allow(loader).to receive(:call).and_return(true)
    expect(restorer('resume', job_id: 'job-2').call).to be(true)
    expect(run.reload).to have_attributes(status: 'loading', job_id: 'job-2', error: nil)
    expect(post_steps).to have_received(:call)
  end

  it 'loads the safety snapshot of an interrupted run' do
    snapshot = Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2').to_s
    run.update!(status: 'interrupted', snapshot_path: snapshot)
    restorer('snapshot').call
    expect(loader).to have_received(:call).with(snapshot)
    expect(run.reload.outcome['loaded_from']).to eq('snapshot')
  end

  it 'stops at awaiting_terminal in terminal mode, then verifies the loaded DB before the post-steps' do
    restorer('terminal').call
    expect(loader).not_to have_received(:call)
    expect(run.reload).to be_awaiting_terminal
    expect(DbRestore::Lock.active?).to be(true)

    allow(ActiveRecord::Base.connection_pool).to receive(:disconnect!)
    restorer('post_steps', job_id: 'job-3').call
    expect(post_steps).to have_received(:call)
    expect(run.reload.outcome['loaded_from']).to eq('terminal')
  end

  it 'keeps waiting for the terminal load when the DB does not look loaded' do
    restorer('terminal').call
    allow(ActiveRecord::Base.connection_pool).to receive(:disconnect!)
    allow(ActiveRecord::Base.connection_pool).to receive(:lease_connection).and_wrap_original do |original|
      conn = original.call
      allow(conn).to receive(:tables).and_return(%w[users])
      conn
    end
    restorer('post_steps', job_id: 'job-3').call
    expect(post_steps).not_to have_received(:call)
    expect(run.reload).to be_awaiting_terminal
    expect(run.error).to include('schema_migrations')
  end

  it 'refuses an unknown mode' do
    expect { restorer('whatever') }.to raise_error(ArgumentError)
  end
end
