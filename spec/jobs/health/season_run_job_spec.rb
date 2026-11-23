# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::SeasonRunJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { closed_health_season }

  it 'runs on the maintenance queue, discarding a duplicate for the same season and group (Solid Queue)' do
    job = described_class.new(season_id: 7, group: 'badges', trigger: 'manual')
    expect(job.queue_name).to eq('maintenance')
    expect(job.concurrency_key).to eq('Health::SeasonRunJob/health-7-badges')
    expect(described_class.concurrency_on_conflict).to eq(:discard)
    expect(described_class.new(season_id: 7, group: 'results', trigger: 'manual').concurrency_key).not_to eq(job.concurrency_key)
  end

  describe '.enqueue' do
    it 'creates the queued run and enqueues the job with its id; a second enqueue is skipped while pending' do
      run = nil
      expect { run = described_class.enqueue(season_id: season.id, group: 'meetings', trigger: 'manual') }
        .to have_enqueued_job(described_class).on_queue('maintenance').at_priority(described_class::PRIORITY_ON_DEMAND)
      expect(run).to have_attributes(status: 'queued', group_key: 'meetings', trigger: 'manual', season_id: season.id)
      expect(run.job_id).to be_present
      expect(enqueued_jobs.last[:args].first).to include('season_id' => season.id, 'group' => 'meetings', 'run_id' => run.id)

      expect { expect(described_class.enqueue(season_id: season.id, group: 'meetings', trigger: 'manual')).to be_nil }
        .not_to have_enqueued_job(described_class)
    end

    it 'fails the stale pending runs first, then enqueues again' do
      stale = FactoryBot.create(:ops_health_run, season_id: season.id, group_key: 'setup', status: 'running', finished_at: nil,
                                                 created_at: 4.hours.ago)
      expect(described_class.enqueue(season_id: season.id, group: 'setup', trigger: 'manual')).to be_present
      expect(stale.reload).to have_attributes(status: 'failed', error_message: include('never finished'))
    end

    it 'enqueues every group of the season at the sweep priority' do
      scope = instance_double(Health::SeasonScope, groups_for: %w[meetings setup])
      runs = described_class.enqueue_season(season_id: season.id, trigger: 'post_commit', scope:,
                                            priority: described_class::PRIORITY_SWEEP)
      expect(runs.map(&:group_key)).to eq(%w[meetings setup])
      expect(runs.map(&:trigger).uniq).to eq(['post_commit'])
    end
  end

  describe '#perform' do
    let(:scope) { instance_double(Health::SeasonScope, entry: health_entry(season, status: :closed)) }

    before(:each) { allow(Health::SeasonScope).to receive(:new).and_return(scope) }

    it 'runs the group on the queued run, recording the duration' do
      FactoryBot.create(:meeting, season:, header_date: season.begin_date + 5.days)
      run = described_class.enqueue(season_id: season.id, group: 'meetings', trigger: 'manual')
      perform_enqueued_jobs
      expect(run.reload).to have_attributes(status: 'succeeded', findings_count: 2)
      expect(run.duration_ms).to be_a(Integer)
    end

    it 'gives a failed run that resolves nothing when a check raises' do
      finding = FactoryBot.create(:ops_health_finding, season_id: season.id)
      allow(Health::Checks::Meetings).to receive(:new).and_raise(RuntimeError, 'kaboom')
      run = described_class.perform_now(season_id: season.id, group: 'meetings', trigger: 'manual')
      expect(run).to have_attributes(status: 'failed', error_message: 'RuntimeError: kaboom')
      expect(finding.reload.status).to eq('open')
    end

    it 'fails the queued run of an unknown season' do
      run = FactoryBot.create(:ops_health_run, season_id: 0, status: 'queued', finished_at: nil)
      described_class.perform_now(season_id: 0, group: 'meetings', trigger: 'manual', run_id: run.id)
      expect(run.reload).to have_attributes(status: 'failed', error_message: 'Season 0 not found')
    end
  end
end
