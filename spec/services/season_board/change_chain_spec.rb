# frozen_string_literal: true

require 'rails_helper'

# 0.10.103: the follow-up of the pending FIN change shared by PipelinePlannerJob and FedernuotoWatchJob.
RSpec.describe SeasonBoard::ChangeChain do
  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:change) { { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k-1' }] } }
  let(:store) { instance_double(FedernuotoWatch::StateStore, pending_change: change) }
  let(:calendar_planner) { instance_double(SeasonBoard::CalendarPlanner, call: :queued) }
  let(:crawl_planner) { instance_double(SeasonBoard::CrawlPlanner, call: ['1'], plan_recrawl: ['3']) }
  let(:calls) { [] }

  def chain = described_class.new(season:, store:).call

  before(:each) do
    allow(SeasonBoard::CalendarPlanner).to receive(:new).and_return(calendar_planner)
    allow(SeasonBoard::CrawlPlanner).to receive(:new).and_return(crawl_planner)
    allow(calendar_planner).to receive(:call) { |*| (calls << :calendar) && :queued }
    allow(crawl_planner).to receive(:call) { |*| (calls << :crawls) && ['1'] }
    allow(crawl_planner).to receive(:plan_recrawl) { |*| (calls << :recrawls) && ['3'] }
  end

  it 'queues the calendar crawl, then the meeting crawls, then the re-crawls of the pending change, in this order' do
    outcome = chain
    expect(outcome).to have_attributes(calendar: :queued, crawls: ['1'], recrawls: ['3'])
    expect(outcome).to be_queued
    expect(calls).to eq(%i[calendar crawls recrawls])
    expect(calendar_planner).to have_received(:call).with(change)
    expect(crawl_planner).to have_received(:call).with(change)
  end

  it 'does nothing without a pending change, a season, or with the master switch off' do
    allow(store).to receive(:pending_change).and_return(nil)
    expect(chain.calendar).to eq(:no_change)
    expect(described_class.new(season: nil, store:).call.calendar).to eq(:no_season)
    allow(store).to receive(:pending_change).and_return(change)
    DataFix::Automation.store!(:enabled, false)
    expect(chain).to have_attributes(calendar: :paused, crawls: [], recrawls: [])
    expect(calls).to be_empty
  end

  it 'goes on with the next step when one fails, and never raises' do
    allow(calendar_planner).to receive(:call).and_raise(RuntimeError, 'boom')
    expect(chain).to have_attributes(calendar: :failed, crawls: ['1'], recrawls: ['3'])
    allow(store).to receive(:pending_change).and_raise(Errno::EACCES)
    expect(chain.calendar).to eq(:failed)
  end
end
