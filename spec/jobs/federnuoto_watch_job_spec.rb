# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatchJob do
  before(:each) { allow(FedernuotoWatch::Checker).to receive(:call).and_return(:unchanged) }

  it 'runs a scheduled (non-manual) check by default' do
    described_class.perform_now
    expect(FedernuotoWatch::Checker).to have_received(:call).with(manual: false)
  end

  it 'runs a manual check when requested' do
    described_class.perform_now(manual: true)
    expect(FedernuotoWatch::Checker).to have_received(:call).with(manual: true)
  end

  it 'is enqueued on the default queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
  end

  it 'is scheduled as a recurring task' do
    recurring = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/recurring.yml'))
    expect(recurring.dig('production', 'federnuoto_watch')).to include('class' => described_class.name)
    expect(recurring.dig('development', 'federnuoto_watch', 'schedule')).to be_present
  end

  it 'also schedules the daily Season board re-check' do
    recurring = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/recurring.yml'))
    expect(recurring.dig('production', 'season_board_recheck')).to include('class' => 'SeasonRecheckJob', 'queue' => 'background')
  end

  describe 'the follow-up of a change (0.10.103: SeasonBoard::ChangeChain, then FedernuotoWatch::ParityCheck)' do
    let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
    let(:outcome) { SeasonBoard::ChangeChain::Outcome.new(calendar: :queued, crawls: ['150091'], recrawls: []) }
    let(:chain) { instance_double(SeasonBoard::ChangeChain, call: outcome) }
    let(:parity_outcome) { FedernuotoWatch::ParityCheck::Outcome.new(status: :pending, parity: nil) }

    before(:each) do
      allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
      allow(SeasonBoard::ChangeChain).to receive(:new).and_return(chain)
      allow(FedernuotoWatch::ParityCheck).to receive(:call).and_return(parity_outcome)
    end

    it 'runs the same chain entry as the planner passes on a detected change, then the parity check' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      expect(described_class.perform_now).to eq(:changed)
      expect(SeasonBoard::ChangeChain).to have_received(:new).with(season:)
      expect(chain).to have_received(:call)
      expect(FedernuotoWatch::ParityCheck).to have_received(:call).with(season:)
    end

    it 'queues a pipeline planner pass after a change' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      expect { described_class.perform_now }.to have_enqueued_job(PipelinePlannerJob).with(trigger: 'FedernuotoWatchJob')
    end

    it 'queues no planner pass while the automation is off (ADMIN2_AUTOMATION=0)' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect { described_class.perform_now }.not_to have_enqueued_job(PipelinePlannerJob)
    end

    %i[unchanged baseline reverted].each do |checked|
      it "runs only the parity check after a #{checked} check" do
        allow(FedernuotoWatch::Checker).to receive(:call).and_return(checked)
        described_class.perform_now
        expect(SeasonBoard::ChangeChain).not_to have_received(:new)
        expect(FedernuotoWatch::ParityCheck).to have_received(:call).with(season:)
      end
    end

    it 'runs nothing after a failed check' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:error)
      expect(described_class.perform_now).to eq(:error)
      expect(SeasonBoard::ChangeChain).not_to have_received(:new)
      expect(FedernuotoWatch::ParityCheck).not_to have_received(:call)
    end

    it 'swallows planning and parity failures' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      allow(chain).to receive(:call).and_raise(RuntimeError, 'boom')
      allow(FedernuotoWatch::ParityCheck).to receive(:call).and_raise(RuntimeError, 'bang')
      expect(described_class.perform_now).to eq(:changed)
    end
  end
end
