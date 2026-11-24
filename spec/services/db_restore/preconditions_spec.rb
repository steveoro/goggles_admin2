# frozen_string_literal: true

require 'rails_helper'

# One example per refused precondition (phase 14, wizard steps 0-1).
RSpec.describe DbRestore::Preconditions do
  let(:queues) { DbRestoreHelpers::FakeQueues.new }
  let(:target) { passing_target }
  let(:session_index) { empty_session_index }

  after(:each) { Ops::Database.reset_state! }

  def check(stage: :entry, **options)
    described_class.new(target:, queues:, session_index:, **options).call(stage:)
  end

  def refused_keys(result)
    result.refused.map(&:key)
  end

  it 'allows a clean local development setup' do
    result = check
    expect(result).to be_allowed
    expect(result.checks.map(&:key)).to eq(%i[environment host database_name ops other_run outbox push_run blocking_jobs reviews])
  end

  it 'refuses outside the development environment' do
    target = DbRestore::Target.new(env: 'test', config: { 'database' => 'goggles_development', 'host' => 'localhost' },
                                   development_database: 'goggles_development')
    expect(refused_keys(described_class.new(target:, queues:, session_index:).call)).to eq([:environment])
  end

  it 'refuses a remote host' do
    target = DbRestore::Target.new(env: 'development', config: { 'database' => 'goggles_development', 'host' => 'db.example.org' },
                                   development_database: 'goggles_development')
    expect(refused_keys(described_class.new(target:, queues:, session_index:).call)).to eq([:host])
  end

  it 'refuses the production database name (and any name but the development one)' do
    production = DbRestore::Target.new(env: 'development', config: { 'database' => 'goggles', 'host' => '127.0.0.1' },
                                       development_database: 'goggles')
    other = DbRestore::Target.new(env: 'development', config: { 'database' => 'goggles_test' }, development_database: 'goggles_development')
    expect(refused_keys(described_class.new(target: production, queues:, session_index:).call)).to eq([:database_name])
    expect(refused_keys(described_class.new(target: other, queues:, session_index:).call)).to eq([:database_name])
  end

  it 'refuses without the ops DB' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    result = check
    expect(refused_keys(result)).to eq([:ops])
    expect(result[:ops].detail).to eq('missing')
  end

  %w[pending held pushing sent in_doubt failed].each do |state|
    it "refuses a #{state} Outbox script" do
      Ops::SqlScript.create!(seq: 980_001, rel_path: "results.new/misc/0980-#{state}.sql", filename: "0980-#{state}.sql", folder: 'misc',
                             kind: 'manual', sha256: 'b' * 64, state:)
      result = check
      expect(refused_keys(result)).to eq([:outbox])
      expect(result[:outbox].items).to eq(["0980-#{state}.sql (#{state})"])
    end
  end

  it 'refuses a running push run' do
    Ops::PushRun.create!(user_id: 1, target_api_url: 'http://localhost:8081', status: 'running', started_at: Time.current, script_ids: [])
    expect(refused_keys(check)).to eq([:push_run])
  end

  it 'refuses a running commit job' do
    queues.claimed_jobs = [claimed_job('DataFixCommitJob', 'pipeline')]
    expect(refused_keys(check)).to eq([:blocking_jobs])
  end

  it 'refuses a running maintenance or health job (class names of other phases)' do
    queues.claimed_jobs = [claimed_job('Maintenance::RunJob', 'maintenance'), claimed_job('Health::SweepJob', 'maintenance')]
    result = check
    expect(refused_keys(result)).to eq([:blocking_jobs])
    expect(result[:blocking_jobs].detail).to eq('Maintenance::RunJob, Health::SweepJob')
  end

  it 'refuses a queued commit, operation or season health job (skipped through the lock, its run would stay queued)' do
    queues.queued_jobs = [claimed_job('Maintenance::RunJob', 'maintenance'), claimed_job('Health::SeasonRunJob', 'maintenance')]
    result = check
    expect(refused_keys(result)).to eq([:blocking_jobs])
    expect(result[:blocking_jobs].items.join).to include('Maintenance::RunJob (maintenance)', 'Health::SeasonRunJob (maintenance)')
    expect(refused_keys(check(stage: :load))).to eq([:blocking_jobs])
  end

  it 'ignores a queued recurring health sweep (stateless: a skipped sweep runs next time)' do
    queues.queued_jobs = [claimed_job('Health::SweepJob', 'maintenance')]
    expect(check).to be_allowed
  end

  it 'refuses Data-Fix reviews in progress without the discard tick' do
    row = DataFix::SessionIndex::Row.new(source_path: 'crawler/data/results.new/262/a.json', season_id: 262, highest_phase: 3,
                                         mtime: Time.current, staging_rows: 12, source_exists: true)
    index = instance_double(DataFix::SessionIndex, rows: [row])
    result = described_class.new(target:, queues:, session_index: index).call
    expect(refused_keys(result)).to eq([:reviews])
    ticked = described_class.new(target:, queues:, session_index: index, confirmations: { 'discard_reviews' => true }).call
    expect(ticked).to be_allowed
    expect(ticked[:reviews].level).to eq(:info)
  end

  it 'lists the other running jobs at entry, and refuses them at load (queues not drained)' do
    own = claimed_job('DbRestore::RestoreJob', 'maintenance', job_id: 'own-job')
    queues.claimed_jobs = [claimed_job('MeetingCrawlJob', 'background'), own]
    entry = check
    expect(entry).to be_allowed
    expect(entry[:running_jobs].detail).to eq('MeetingCrawlJob')
    load = check(stage: :load, own_job_ids: ['own-job'])
    expect(refused_keys(load)).to eq([:drain])
    queues.claimed_jobs = [own]
    expect(check(stage: :load, own_job_ids: ['own-job'])[:drain]).to be_ok
  end

  it 'refuses while another run is open' do
    other = create_restore_run(status: 'ready')
    result = check
    expect(refused_keys(result)).to eq([:other_run])
    expect(check(run: other)).to be_allowed
  end

  it 'warns when the queue DB is not readable' do
    queues.available = false
    result = check
    expect(result).to be_allowed
    expect(result[:queue_db].level).to eq(:warning)
  end

  it 'translates the refusals' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(check.messages).to eq([I18n.t('db_restore.checks.ops.refused', detail: 'missing')])
  end
end
