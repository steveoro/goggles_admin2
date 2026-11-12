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

  describe 'automatic crawl planning' do
    let(:change) { { 'added' => [{ 'url' => 'https://www.federnuoto.it/x#/risultati/150091:m.html' }] } }
    let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
    let(:planner) { instance_double(SeasonBoard::CrawlPlanner, call: ['150091']) }
    let(:store) { instance_double(FedernuotoWatch::StateStore, pending_change: change) }

    before(:each) do
      allow(FedernuotoWatch::StateStore).to receive(:new).and_return(store)
      allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
      allow(SeasonBoard::CrawlPlanner).to receive(:new).and_return(planner)
    end

    it 'plans the crawls for the pending change when the check detects a change' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      expect(described_class.perform_now).to eq(:changed)
      expect(SeasonBoard::CrawlPlanner).to have_received(:new).with(season:)
      expect(planner).to have_received(:call).with(change)
    end

    it 'does not plan anything when nothing changed' do
      described_class.perform_now
      expect(SeasonBoard::CrawlPlanner).not_to have_received(:new)
    end

    it 'swallows planning failures' do
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      allow(planner).to receive(:call).and_raise(RuntimeError, 'boom')
      expect(described_class.perform_now).to eq(:changed)
    end
  end
end
