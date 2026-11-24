# frozen_string_literal: true

require 'rails_helper'

# Runs against the test DB inside the example transaction (rolled back): the MySQL pool disconnect is stubbed,
# so the pinned test connection survives.
RSpec.describe DbRestore::PostSteps do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:queues) { DbRestoreHelpers::FakeQueues.new }
  let(:fingerprint) { instance_double(Ops::DbFingerprint, verdict: 'green', id: 77) }
  let(:drift_job) { class_double(DriftCheckJob, perform_now: fingerprint) }
  let(:taken_at) { Time.zone.parse('2026-11-22 21:30:01') }
  let(:run) do
    lock_with_run(status: 'loading', user_id: admin_user.id, dump_taken_at: taken_at,
                  preserved: { 'api_url' => 'http://localhost:8081', 'api_url_choice' => 'keep', 'user_id' => admin_user.id,
                               'jwt' => 'preserved.jwt.value', 'paused_queues' => %w[default outbox], 'captured_at' => 1.minute.ago.iso8601 })
  end

  before(:each) do
    allow(ActiveRecord::Base.connection_pool).to receive(:disconnect!)
    allow(DataFix::StagingPurger).to receive(:purge_all!).and_return({ laps: 2, individual_results: 3 })
  end

  after(:each) { Ops::Database.reset_state! }

  def as_after_a_production_load
    conn = ActiveRecord::Base.connection
    conn.update("UPDATE ar_internal_metadata SET value = 'production' WHERE #{conn.quote_column_name('key')} = 'environment'")
    cfg = GogglesDb::AppParameter.config
    cfg.settings(:framework_urls).value['api'] = 'https://production-api.example.test'
    cfg.save!
    GogglesDb::AppParameter.maintenance = true
    admin_user.update_columns(jwt: 'production.jwt') # rubocop:disable Rails/SkipsModelValidations
  end

  def post_steps
    described_class.new(run:, queues:, drift_job:).call
  end

  it 'resets the environment, re-applies the API URL and the JWT, turns maintenance off and purges the staging tables' do
    as_after_a_production_load
    post_steps
    conn = ActiveRecord::Base.connection
    expect(conn.select_value("SELECT value FROM ar_internal_metadata WHERE #{conn.quote_column_name('key')} = 'environment'")).to eq(Rails.env.to_s)
    expect(APIProxy.configured_base_url).to eq('http://localhost:8081')
    expect(admin_user.reload.jwt).to eq('preserved.jwt.value')
    expect(GogglesDb::AppParameter.versioning_row.reload.maintenance?).to be(false)
    expect(DataFix::StagingPurger).to have_received(:purge_all!)
    expect(run.reload.preserved).not_to have_key('jwt')
    expect(run.outcome).to include('environment' => Rails.env.to_s, 'api_url' => 'kept', 'jwt' => 'applied', 'maintenance' => 'off',
                                   'staging_purged' => 5)
  end

  it 'reports (never runs) the engine migrations missing from the restored schema_migrations' do
    allow(DbRestore).to receive(:local_schema_versions).and_return(%w[20201231000000 29991231000000])
    conn = ActiveRecord::Base.connection
    conn.insert("INSERT IGNORE INTO schema_migrations (version) VALUES ('20201231000000')") # rubocop:disable Rails/SkipsModelValidations
    post_steps
    expect(run.reload.outcome['pending_migrations']).to eq(['29991231000000'])
  end

  it 'bumps db_epoch and data_fix.db_generation, covers the remote writes up to the dump time, resumes the queues and releases the lock' do
    epoch = Ops::Setting.db_epoch
    generation = DataFix::Pipeline.db_generation
    Ops::RemoteWrite.acknowledge!(taken_at - 1.day)
    post_steps
    expect(Ops::Setting.db_epoch).to eq(epoch + 1)
    expect(DataFix::Pipeline.db_generation).to eq(generation + 1)
    expect(Ops::RemoteWrite.acknowledged_at).to be_within(1.second).of(taken_at)
    expect(queues.resumed).to eq(%w[default outbox])
    expect(queues.resumed_while_locked).to eq([false])
    expect(DbRestore::Lock.active?).to be(false)
  end

  it 'never moves the remote-write acknowledgement back' do
    later = taken_at + 1.day
    Ops::RemoteWrite.acknowledge!(later)
    post_steps
    expect(Ops::RemoteWrite.acknowledged_at).to be_within(1.second).of(later)
  end

  it 'runs the post-restore DB sync check after releasing the lock, then finishes the run with an event' do
    allow(drift_job).to receive(:perform_now) do
      expect(DbRestore::Lock.active?).to be(false)
      fingerprint
    end
    post_steps
    expect(drift_job).to have_received(:perform_now).with(trigger: 'post_restore')
    expect(run.reload).to have_attributes(status: 'finished', step: 'finished')
    expect(run.outcome).to include('drift_verdict' => 'green', 'db_fingerprint_id' => 77)
    event = Ops::Event.find_by(kind: 'db_restore.finished')
    expect(event).to have_attributes(level: 'success', subject_key: run.id.to_s)
  end

  it 'finishes even when the DB sync check fails' do
    allow(drift_job).to receive(:perform_now).and_raise(StandardError, 'API down')
    post_steps
    expect(run.reload).to be_finished
    expect(run.outcome['drift_error']).to include('API down')
  end

  it "keeps the dump's API URL when the operator chose it" do
    as_after_a_production_load
    run.update!(preserved: run.preserved.merge('api_url_choice' => 'dump'))
    post_steps
    expect(APIProxy.configured_base_url).to eq('https://production-api.example.test')
    expect(run.reload.outcome['api_url']).to eq('dump')
  end

  it 'reports a user missing from the dump (one more sign-in)' do
    run.update!(preserved: run.preserved.merge('user_id' => 0))
    post_steps
    expect(run.reload.outcome['jwt']).to eq('user_missing')
  end

  it 'accepts the DriftCheckJob trigger (Ops::DbFingerprint::TRIGGERS)' do
    expect(Ops::DbFingerprint::TRIGGERS).to include('post_restore')
    expect(I18n.t('db_sync.triggers.post_restore')).to be_present
  end
end
