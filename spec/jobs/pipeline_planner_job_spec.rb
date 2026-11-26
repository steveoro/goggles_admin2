# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelinePlannerJob do
  include ActiveJob::TestHelper

  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:plan) { SeasonBoard::PipelinePlanner::Plan.new(prepares: ['150091'], extractions: [], skipped: {}) }
  let(:planner) { instance_double(SeasonBoard::PipelinePlanner, call: plan) }

  before(:each) do
    allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
    allow(SeasonBoard::PipelinePlanner).to receive(:new).and_return(planner)
  end

  it 'runs on the default queue, one pass at a time' do
    job = described_class.new
    expect(job.queue_name).to eq('default')
    expect(described_class.concurrency_limit).to eq(1)
    expect(job.concurrency_key).to end_with('pipeline_planner')
  end

  it 'runs one planner pass on the board season only' do
    expect(described_class.perform_now(trigger: 'schedule')).to eq(plan)
    expect(SeasonBoard::PipelinePlanner).to have_received(:new).with(season:)
  end

  it 'does nothing with the automation master switch off' do
    DataFix::Automation.store!(:enabled, false)
    expect(described_class.perform_now.prepares).to be_empty
    expect(SeasonBoard::PipelinePlanner).not_to have_received(:new)
  end

  it 'never raises' do
    allow(planner).to receive(:call).and_raise(RuntimeError, 'boom')
    expect { described_class.perform_now }.not_to raise_error
  end

  describe 'activity reconciliation (0.10.99)' do
    let(:reconciler) { instance_double(SeasonBoard::ActivityReconciler, call: []) }

    before(:each) { allow(SeasonBoard::ActivityReconciler).to receive(:new).and_return(reconciler) }

    it 'reconciles the board activity first, also with the master switch off (it queues nothing)' do
      DataFix::Automation.store!(:enabled, false)
      described_class.perform_now
      expect(reconciler).to have_received(:call)
      expect(SeasonBoard::PipelinePlanner).not_to have_received(:new)
    end

    it 'runs the planner pass even when the reconciliation fails' do
      allow(reconciler).to receive(:call).and_raise(RuntimeError, 'boom')
      expect(described_class.perform_now).to eq(plan)
    end
  end

  describe '.enqueue_after' do
    it 'enqueues a pass after a job when the automation is on' do
      expect { expect(described_class.enqueue_after('MeetingCrawlJob')).to be true }
        .to have_enqueued_job(described_class).with(trigger: 'MeetingCrawlJob')
    end

    it 'enqueues nothing with ADMIN2_AUTOMATION=0' do
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect { expect(described_class.enqueue_after('MeetingCrawlJob')).to be false }.not_to have_enqueued_job(described_class)
    end
  end

  it 'is scheduled every 15 minutes on the default queue (config/recurring.yml)' do
    config = YAML.safe_load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(config.dig('default', 'pipeline_planner')).to eq('class' => 'PipelinePlannerJob', 'queue' => 'default', 'schedule' => 'every 15 minutes')
  end
end
