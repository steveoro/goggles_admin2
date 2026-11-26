# frozen_string_literal: true

require 'rails_helper'

# 0.10.103: the automatic crawl of the FIN 'Eventi' calendar (after a FIN change, and once a day).
RSpec.describe SeasonBoard::CalendarPlanner do
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
  let(:data_dir) { Pathname.new(Dir.mktmpdir('calendar-planner')) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:calendar_key) { Sources::CrawlRequest.eventi_calendar(season).key }
  let(:change) { { 'detected_at' => 1.hour.ago.iso8601, 'added' => [] } }

  def planner(now: Time.current) = described_class.new(season:, activity_log:, data_dir:, now:)

  def finish_calendar(status, at: Time.current)
    travel_to(at) do
      activity_log.queue!(calendar_key, kind: :crawl, origin: :auto)
      activity_log.finish!(calendar_key, kind: :crawl, status:)
    end
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Scheduler).to receive(:calendar_crawl!).and_return(true)
  end

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  describe '#call (after a FIN change)' do
    it 'queues the Eventi calendar crawl (automatic) while a change is pending, recording the attempt first' do
      expect(planner.call(change)).to eq(:queued)
      expect(SeasonBoard::Scheduler).to have_received(:calendar_crawl!).with(season:, origin: :auto)
      expect(Ops::Setting.fetch(described_class::LAST_AUTO_KEY)).to be_present
    end

    it 'queues nothing without a pending change or a season' do
      expect(planner.call(nil)).to eq(:no_change)
      expect(planner.call({})).to eq(:no_change)
      expect(described_class.new(season: nil).call(change)).to eq(:no_season)
      expect(SeasonBoard::Scheduler).not_to have_received(:calendar_crawl!)
    end

    it 'queues nothing once a calendar crawl finished since the change was detected (done only)' do
      finish_calendar(:done, at: 30.minutes.ago)
      expect(planner.call(change)).to eq(:crawled_since_change)
      finish_calendar(:done, at: 2.hours.ago)
      expect(planner.call(change)).to eq(:queued)
    end

    it 'counts a calendar file written since the change as a finished crawl' do
      dir = data_dir.join('calendar.new', '262')
      FileUtils.mkdir_p(dir)
      FileUtils.touch(dir.join("#{Date.current.strftime('%Y%m%d')}-262-2-FIN-calendar.csv"))
      expect(planner.call(change)).to eq(:crawled_since_change)
    end

    it 'queues nothing while the calendar crawl is queued or running' do
      activity_log.queue!(calendar_key, kind: :crawl, origin: :manual)
      expect(planner.call(change)).to eq(:busy)
    end

    it 'tries again after a failed crawl only once the last automatic attempt is older than 6 hours' do
      expect(planner.call(change)).to eq(:queued)
      finish_calendar(:failed)
      expect(planner(now: 5.hours.from_now).call(change)).to eq(:recent_attempt)
      expect(planner(now: 6.hours.from_now + 1.minute).call(change)).to eq(:queued)
      expect(SeasonBoard::Scheduler).to have_received(:calendar_crawl!).twice
    end

    it "queues nothing with the 'auto_calendar' switch off, or the master switch off" do
      DataFix::Automation.store!(:auto_calendar, false)
      expect(planner.call(change)).to eq(:switch_off)
      DataFix::Automation.store!(:auto_calendar, true)
      DataFix::Automation.store!(:enabled, false)
      expect(planner.call(change)).to eq(:switch_off)
      expect(SeasonBoard::Scheduler).not_to have_received(:calendar_crawl!)
    end

    it 'fails closed: an attempt time that cannot be read or written queues nothing' do
      allow(Ops::Setting).to receive(:fetch).and_call_original
      allow(Ops::Setting).to receive(:fetch).with(described_class::LAST_AUTO_KEY).and_raise(ActiveRecord::StatementInvalid, 'locked')
      expect(planner.call(change)).to eq(:recent_attempt)
      allow(Ops::Setting).to receive(:fetch).with(described_class::LAST_AUTO_KEY).and_return(nil)
      allow(Ops::Setting).to receive(:store!).and_raise(ActiveRecord::StatementInvalid, 'locked')
      expect(planner.call(change)).to eq(:unrecorded)
      expect(SeasonBoard::Scheduler).not_to have_received(:calendar_crawl!)
    end

    it 'reports a refused or failed enqueue' do
      allow(SeasonBoard::Scheduler).to receive(:calendar_crawl!).and_return(false)
      expect(planner.call(change)).to eq(:refused)
      Ops::Setting.where(key: described_class::LAST_AUTO_KEY).delete_all
      allow(SeasonBoard::Scheduler).to receive(:calendar_crawl!).and_raise(RuntimeError, 'no queue')
      expect(planner.call(change)).to eq(:failed)
    end
  end

  describe '#call_daily' do
    it 'queues one crawl a day' do
      expect(planner.call_daily).to eq(:queued)
      expect(planner(now: 19.hours.from_now).call_daily).to eq(:recent_attempt)
      expect(planner(now: 21.hours.from_now).call_daily).to eq(:queued)
      expect(Ops::Setting.fetch(described_class::LAST_DAILY_KEY)).to be_present
    end

    it 'is skipped after a calendar crawl finished in the last 6 hours, and obeys the switch' do
      finish_calendar(:done, at: 2.hours.ago)
      expect(planner.call_daily).to eq(:crawled_recently)
      DataFix::Automation.store!(:auto_calendar, false)
      expect(planner.call_daily).to eq(:switch_off)
    end

    it 'keeps its own attempt time (a change-driven attempt does not hold it back)' do
      Ops::Setting.store!(described_class::LAST_AUTO_KEY, Time.current.iso8601)
      expect(planner.call_daily).to eq(:queued)
    end
  end

  describe '.ended_since?' do
    it 'is true after a done or failed crawl since the time' do
      expect(described_class.ended_since?(season, 1.hour.ago, activity_log:, data_dir:)).to be false
      finish_calendar(:failed)
      expect(described_class.ended_since?(season, 1.hour.ago, activity_log: activity_log.reload!, data_dir:)).to be true
      expect(described_class.finished_since?(season, 1.hour.ago, activity_log:, data_dir:)).to be false
    end
  end
end
