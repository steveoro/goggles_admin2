# frozen_string_literal: true

require 'rails_helper'
require_relative '../services/season_board/disk_fixtures'

RSpec.describe MeetingCrawlJob do
  include SeasonBoardDiskFixtures

  # Scriptable stand-in for CrawlerClient: #status returns the head of +statuses+ (the last one
  # repeats; Procs are called with the fake clock time); #pull_meeting runs +on_pull+ and
  # switches to +after_pull+.
  let(:fake_crawler_class) do
    Class.new do
      attr_accessor :statuses, :after_pull, :on_pull, :pull_result
      attr_reader :pulls

      def initialize(clock)
        @clock = clock
        @pulls = []
        @statuses = []
        @after_pull = []
        @pull_result = CrawlerClient::Result.new(ok: true, code: 200, body: {}, error: nil)
      end

      def status
        item = @statuses.size > 1 ? @statuses.shift : @statuses.first
        item.respond_to?(:call) ? item.call(@clock.call) : item
      end

      def pull_meeting(season_id:, url:)
        @pulls << { season_id:, url: }
        on_pull&.call
        @statuses = after_pull.dup if pull_result.ok?
        pull_result
      end
    end
  end

  let(:data_dir) { Dir.mktmpdir('meeting-crawl-job') }
  let(:fin_id) { '150091' }
  let(:url) { results_url(fin_id) }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:calendar) { nil }
  let(:db_index) { instance_double(SeasonBoard::DbIndex, calendar_for: calendar) }
  let(:launch_result) { :already_running }
  let(:launcher) { instance_double(CrawlerLauncher, ensure_running!: launch_result) }
  # (in the past, so that the files written by the fake crawl have a real mtime after the fake-clock start)
  let(:start_time) { 10.minutes.ago.change(usec: 0) }
  let(:clock_state) { { now: start_time, slept: [] } }
  let(:clock) { -> { clock_state[:now] } }
  let(:crawler) { fake_crawler_class.new(clock) }

  def ts(time) = time.utc.strftime('%Y%m%d-%H%M%S')

  def idle_status(time = start_time - 1.hour) = { 'timestamp' => ts(time), 'status' => 'OK, done, idle', 'detail' => 'Done.' }

  def running_status(time) = { 'timestamp' => ts(time), 'status' => 'OK, processing 1/1', 'detail' => 'Processing' }

  # Crawl end status, written "now" (fake clock)
  def done_now = ->(now) { { 'timestamp' => ts(now), 'status' => 'OK, done, idle', 'detail' => 'Direct URL processing done' } }

  def write_snapshot(rows)
    FedernuotoWatch::StateStore.new.update { |state| state.merge('rows' => rows) }
  end

  def linked_calendar
    meeting = SeasonBoard::DbIndex::MeetingInfo.new(id: 19_000, description: 'M', code: 'm', header_date: nil, cancelled: false,
                                                    results_acquired: false, manifest: true, mir_count: 0, mrr_count: 0)
    SeasonBoard::DbIndex::CalendarInfo.new(id: 1700, fin_event_id: fin_id, meeting_id: 19_000, meeting_code: 'm', meeting_name: 'M',
                                           meeting_place: 'X', scheduled_date: '8', year: '2026', month: 'Nov', cancelled: false,
                                           results_link: nil, meeting:)
  end

  def age!(path, time = 2.hours.ago.to_time)
    File.utime(time, time, path)
    path
  end

  def perform(job_url = url)
    described_class.perform_now(season_id: 262, fin_event_id: fin_id, url: job_url)
  end

  def crawl_entry = activity_log.entry(fin_id, :crawl)

  before(:each) do
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
    write_snapshot([{ 'key' => 'k', 'url' => url, 'date' => '08/11', 'year' => '2026' }])
    allow(GogglesDb::Season).to receive(:find_by).with(id: 262).and_return(season)
    allow(SeasonBoard::DbIndex).to receive(:new).and_return(db_index)
    allow(SeasonBoard::Notifier).to receive(:ping)
    state = clock_state
    described_class.clock = clock
    described_class.sleeper = lambda { |seconds|
      state[:slept] << seconds
      state[:now] += seconds
    }
    described_class.crawler_client_factory = -> { crawler }
    described_class.launcher_factory = -> { launcher }
    described_class.data_dir = data_dir
    crawler.statuses = [idle_status]
    crawler.after_pull = [idle_status, running_status(start_time), done_now]
  end

  after(:each) do
    described_class.clock = -> { Time.current }
    described_class.sleeper = ->(seconds) { sleep(seconds) }
    described_class.crawler_client_factory = -> { CrawlerClient.new }
    described_class.launcher_factory = -> { CrawlerLauncher.new }
    described_class.data_dir = nil
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
  end

  it 'is enqueued on the background queue' do
    expect { described_class.perform_later(season_id: 262, fin_event_id: fin_id, url:) }
      .to have_enqueued_job(described_class).on_queue('background')
  end

  it 'keeps the concurrency limit above the crawl timeout' do
    expect(described_class.concurrency_duration).to be > described_class::CRAWL_TIMEOUT + described_class::IDLE_WAIT_TIMEOUT
  end

  context 'when the crawl yields results (unlinked meeting)' do
    before(:each) do
      crawler.on_pull = lambda {
        write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
        write_file('manifests', 'manifest-m.pdf', '%PDF')
      }
    end

    it 'crawls the snapshot URL in layout-2 direct mode & closes the activity as done' do
      perform
      expect(crawler.pulls).to eq([{ season_id: 262, url: }])
      expect(crawl_entry).to have_attributes(status: :done, message: 'results found')
      expect(File).to exist(path_for('results.new', 'm.json'))
      expect(File).to exist(path_for('manifests', 'manifest-m.pdf'))
      expect(SeasonBoard::Notifier).to have_received(:ping)
    end

    it 'pauses after the crawl' do
      perform
      expect(clock_state[:slept].last).to eq(described_class::PAUSE_AFTER_CRAWL)
    end

    it 'inherits the origin of the queued entry' do
      activity_log.queue!(fin_id, kind: :crawl, origin: :auto, url:)
      perform
      expect(crawl_entry).to have_attributes(origin: :auto, status: :done)
    end
  end

  context 'when the crawl yields results for a linked meeting' do
    let(:calendar) { linked_calendar }

    it 'moves only the re-downloaded manifest PDF to manifests.done' do
      crawler.on_pull = lambda {
        write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true))
        write_file('manifests', 'manifest-m.pdf', '%PDF')
      }
      perform
      expect(crawl_entry).to have_attributes(status: :done, message: 'results found')
      expect(File).to exist(path_for('results.new', 'm.json'))
      expect(File).not_to exist(path_for('manifests', 'manifest-m.pdf'))
      expect(File).to exist(path_for('manifests.done', 'manifest-m.pdf'))
    end
  end

  context 'when the crawl is result-free for a linked meeting' do
    let(:calendar) { linked_calendar }

    it 'deletes only the fresh redundant LT2 & manifest PDF' do
      old_lt2 = age!(write_json('results.new', 'old.json', lt2_hash(fin_id:)))
      old_pdf = age!(write_file('manifests', 'manifest-old.pdf', '%PDF'))
      other = write_json('results.new', 'other.json', lt2_hash(fin_id: '150092'))
      crawler.on_pull = lambda {
        write_json('results.new', 'm.json', lt2_hash(fin_id:))
        write_file('manifests', 'manifest-m.pdf', '%PDF')
      }
      perform
      expect(crawl_entry.status).to eq(:done)
      expect(crawl_entry.message).to start_with('no results yet')
      expect(File).not_to exist(path_for('results.new', 'm.json'))
      expect(File).not_to exist(path_for('manifests', 'manifest-m.pdf'))
      expect([old_lt2, old_pdf, other]).to all(satisfy { |path| File.exist?(path) })
    end

    it 'keeps a fresh LT2 having an LT4 working copy or phase files' do
      write_json('results.new', 'm-lt4.json', lt4_hash(fin_id:))
      crawler.on_pull = -> { write_json('results.new', 'm.json', lt2_hash(fin_id:)) }
      perform
      expect(crawl_entry).to have_attributes(status: :done, message: 'no results yet')
      expect(File).to exist(path_for('results.new', 'm.json'))
    end
  end

  context 'when the result-free crawl is for an unlinked meeting' do
    it 'keeps every file' do
      crawler.on_pull = lambda {
        write_json('results.new', 'm.json', lt2_hash(fin_id:))
        write_file('manifests', 'manifest-m.pdf', '%PDF')
      }
      perform
      expect(crawl_entry).to have_attributes(status: :done, message: 'no results yet')
      expect(File).to exist(path_for('results.new', 'm.json'))
      expect(File).to exist(path_for('manifests', 'manifest-m.pdf'))
    end
  end

  it 'fails when no fresh output file shows up for the FIN id' do
    age!(write_json('results.new', 'old.json', lt2_hash(fin_id:, results: true)))
    perform
    expect(crawl_entry).to have_attributes(status: :failed, message: 'no output file found for this FIN id')
  end

  it 'fails when the crawler server cannot be started' do
    allow(launcher).to receive(:ensure_running!).and_return(:failed)
    perform
    expect(crawl_entry.status).to eq(:failed)
    expect(crawl_entry.message).to include('cannot be started')
    expect(crawler.pulls).to be_empty
    expect(SeasonBoard::Notifier).to have_received(:ping)
  end

  it 'fails with a timeout when the crawl never ends' do
    crawler.after_pull = [->(now) { running_status(now) }]
    perform
    expect(crawl_entry).to have_attributes(status: :failed, message: 'timeout after 30 min')
    expect(clock_state[:now] - start_time).to be >= described_class::CRAWL_TIMEOUT
  end

  it 'fails when the crawler reports an error' do
    crawler.after_pull = [->(now) { { 'timestamp' => ts(now), 'status' => 'ERROR', 'detail' => 'TimeoutError: boom' } }]
    perform
    expect(crawl_entry).to have_attributes(status: :failed, message: 'crawler error: TimeoutError: boom')
  end

  it 'fails when the crawler API call is refused' do
    crawler.pull_result = CrawlerClient::Result.new(ok: false, code: nil, body: nil, error: 'Errno::ECONNREFUSED')
    perform
    expect(crawl_entry.status).to eq(:failed)
    expect(crawl_entry.message).to include('ECONNREFUSED')
  end

  it 'does not mistake the previous (unchanged) final status for the end of the crawl' do
    crawler.on_pull = -> { write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true)) }
    same_second = idle_status(start_time)
    crawler.statuses = [same_second]
    crawler.after_pull = [same_second, same_second, done_now]
    perform
    expect(crawl_entry.status).to eq(:done)
    expect(clock_state[:slept].count(described_class::POLL_INTERVAL)).to eq(3)
  end

  describe 'waiting for another crawl' do
    it 'waits until a live crawl ends before calling the API' do
      crawler.statuses = [running_status(start_time), running_status(start_time), idle_status(start_time)]
      crawler.on_pull = -> { write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true)) }
      perform
      expect(crawler.pulls.size).to eq(1)
      expect(crawl_entry.status).to eq(:done)
    end

    it 'gives up when the other crawl is still running after the idle wait timeout' do
      crawler.statuses = [->(now) { running_status(now) }]
      perform
      expect(crawler.pulls).to be_empty
      expect(crawl_entry).to have_attributes(status: :failed, message: 'crawler busy with another crawl (OK, processing 1/1)')
    end

    it 'ignores a stale running status file (a dead run)' do
      crawler.statuses = [running_status(start_time - 2.hours)]
      crawler.on_pull = -> { write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true)) }
      perform
      expect(crawler.pulls.size).to eq(1)
      expect(crawl_entry.status).to eq(:done)
    end
  end

  describe 'URL & season checks' do
    it 'fails without crawling when the FIN id is no longer on the watcher snapshot' do
      write_snapshot([{ 'key' => 'k', 'url' => results_url('150099') }])
      perform
      expect(crawler.pulls).to be_empty
      expect(crawl_entry).to have_attributes(status: :failed, message: 'FIN id no longer on the watcher snapshot')
    end

    it 'crawls the snapshot URL, not the given one' do
      crawler.on_pull = -> { write_json('results.new', 'm.json', lt2_hash(fin_id:, results: true)) }
      perform("https://evil.example.com/risultati/#{fin_id}:x.html")
      expect(crawler.pulls).to eq([{ season_id: 262, url: }])
    end

    it 'fails for an unknown season' do
      allow(GogglesDb::Season).to receive(:find_by).with(id: 262).and_return(nil)
      perform
      expect(crawl_entry).to have_attributes(status: :failed, message: 'unknown season 262')
    end
  end

  it 'closes the activity as failed (without raising) on unexpected errors' do
    allow(launcher).to receive(:ensure_running!).and_raise(ArgumentError, 'kaboom')
    expect { perform }.not_to raise_error
    expect(crawl_entry).to have_attributes(status: :failed, message: 'error: ArgumentError: kaboom')
    expect(SeasonBoard::Notifier).to have_received(:ping)
  end
end
