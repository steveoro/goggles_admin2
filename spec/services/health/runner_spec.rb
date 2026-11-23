# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Runner do
  let(:season) { closed_health_season }
  let(:scope) { instance_double(Health::SeasonScope, entry: health_entry(season, status: :closed)) }
  let(:data_dir) { Dir.mktmpdir }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def runner(group, **options)
    described_class.new(season:, group:, trigger: 'manual', scope:, data_dir:, **options)
  end

  before(:each) do
    meeting = FactoryBot.create(:meeting, season:, header_date: season.begin_date + 10.days, cancelled: false)
    FactoryBot.create(:calendar_with_blank_meeting, season:, cancelled: false)
    health_add_mir(meeting)
  end

  it 'records a succeeded run with counts, duration, db_epoch, stamp and check versions, then pings the pages' do
    allow(Health::Notifier).to receive(:ping)
    run = runner('meetings', job_id: 'job-1').call
    expect(run.reload).to have_attributes(status: 'succeeded', season_id: season.id, group_key: 'meetings', trigger: 'manual',
                                          job_id: 'job-1', db_epoch: Ops::Setting.db_epoch, findings_count: 2, new_count: 2)
    expect(run.duration_ms).to be >= 0
    expect(run.stamp).to eq(Health::Stamp.new(season_id: season.id, data_dir:).digest)
    expect(run.check_versions).to eq(Health::Registry.versions_for('meetings'))
    expect(run.counts['calendars.unlinked']).to include('open' => 1, 'new' => 1)
    expect(run.counts['meetings.results_flag']).to include('open' => 1)
    expect(Ops::HealthFinding.for_season(season.id).count).to eq(2)
    expect(Health::Notifier).to have_received(:ping)
  end

  it 'never writes to the primary DB, for every group' do
    Ops::HealthRun::GROUPS.each do |group|
      statements = primary_db_statements { expect(runner(group).call.status).to eq('succeeded'), group }
      expect(statements).not_to be_empty, "#{group}: no primary DB read seen"
      writes = statements.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)
      expect(writes).to be_empty, "#{group}: #{writes.first(3).inspect}"
    end
  end

  it 'records a failed run that resolves nothing when a check raises' do
    runner('meetings').call
    allow(Health::Checks::Meetings).to receive(:new).and_raise(ActiveRecord::StatementInvalid, 'boom')
    run = runner('meetings').call
    expect(run).to have_attributes(status: 'failed', error_message: include('boom'))
    expect(run.finished_at).to be_present
    expect(Ops::HealthFinding.for_season(season.id).pluck(:status).uniq).to eq(['open'])
  end

  it 'records a skipped run, without running the checks, for an unchanged stamp of a heavy group' do
    first = runner('results', skip_unchanged: true).call
    expect(first.status).to eq('succeeded')
    allow(Health::Checks::Results).to receive(:new).and_call_original
    second = runner('results', skip_unchanged: true).call
    expect(second).to have_attributes(status: 'skipped', stamp: first.stamp)
    expect(Health::Checks::Results).not_to have_received(:new)
  end

  it 'runs again when the stamp changed or for a cheap group' do
    runner('results', skip_unchanged: true).call
    FactoryBot.create(:meeting, season:)
    expect(runner('results', skip_unchanged: true).call.status).to eq('succeeded')
    runner('meetings', skip_unchanged: true).call
    expect(runner('meetings', skip_unchanged: true).call.status).to eq('succeeded')
  end

  it 'uses the queued run it was given and keeps only the last runs per group' do
    queued = FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'setup', status: 'queued', started_at: nil,
                                                finished_at: nil, job_id: 'job-9')
    expect(runner('setup', run: queued).call.id).to eq(queued.id)
    expect(queued.reload).to have_attributes(status: 'succeeded', job_id: 'job-9')
    stub_const('Ops::HealthRun::KEPT_PER_GROUP', 2)
    3.times { runner('setup').call }
    expect(Ops::HealthRun.for_season(season.id).for_group('setup').count).to eq(2)
  end

  it 'does nothing without the ops DB' do
    allow(Ops).to receive(:available?).and_return(false)
    expect(runner('meetings').call).to be_nil
  end
end
