# frozen_string_literal: true

require 'rails_helper'

# Phase 15: the manual crawls of the Sources crawler tab. The crawler is a scriptable fake (no Node server, no
# network); every file lives under a temporary data root; the clock runs through ActiveSupport time travel.
RSpec.describe SourceCrawlJob do
  include ActiveSupport::Testing::TimeHelpers

  # Scriptable stand-in for CrawlerClient: #status returns the head of +statuses+ (the last one repeats; Procs are
  # called with the current time); every crawl command records its call, runs +on_pull+ and switches to +after_pull+.
  let(:fake_crawler_class) do
    Class.new do
      attr_accessor :statuses, :after_pull, :on_pull, :pull_result
      attr_reader :calls

      def initialize
        @calls = []
        @statuses = []
        @after_pull = []
        @pull_result = CrawlerClient::Result.new(ok: true, code: 200, body: {}, error: nil)
      end

      def status
        item = @statuses.size > 1 ? @statuses.shift : @statuses.first
        item.respond_to?(:call) ? item.call(Time.current) : item
      end

      %i[pull_meeting pull_calendar pull_results_from_file pull_microplus pull_ficr pull_goandswim].each do |command|
        define_method(command) do |**args|
          @calls << [command, args]
          on_pull&.call
          @statuses = after_pull.dup if pull_result.ok?
          pull_result
        end
      end
    end
  end

  let(:data_root) { Pathname.new(Dir.mktmpdir('source-crawl-job-')) }
  let(:season_id) { 242 }
  let(:crawler) { fake_crawler_class.new }
  let(:launcher) { instance_double(CrawlerLauncher, ensure_running!: :already_running) }
  let(:slept) { [] }
  let(:microplus_url) { 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php' }
  let(:activity_log) { SeasonBoard::ActivityLog.new }

  def ts(time) = time.utc.strftime('%Y%m%d-%H%M%S')
  def idle_status(time = 1.hour.ago) = { 'timestamp' => ts(time), 'status' => 'OK, done, idle', 'detail' => 'Done.' }
  def running_now = ->(now) { { 'timestamp' => ts(now), 'status' => 'OK, processing 1/1', 'detail' => 'Processing' } }
  def done_now = ->(now) { { 'timestamp' => ts(now), 'status' => 'OK, done, idle', 'detail' => 'Done.' } }

  def request(kind: 'microplus', **args)
    Sources::CrawlRequest.from({ kind:, season_id:, url: microplus_url }.merge(args))
  end

  def perform(req = request)
    described_class.perform_now(**req.to_job_args, key: req.key, label: req.label)
  end

  def write_result(name)
    dir = data_root.join('results.new', season_id.to_s)
    FileUtils.mkdir_p(dir)
    File.write(dir.join(name), { 'layoutType' => 4, 'name' => 'Trofeo' }.to_json)
  end

  before(:each) do
    FileUtils.mkdir_p(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    list = slept
    described_class.sleeper = lambda { |seconds|
      list << seconds
      travel(seconds)
    }
    described_class.crawler_client_factory = -> { crawler }
    described_class.launcher_factory = -> { launcher }
    described_class.data_dir = data_root
    allow(SeasonBoard::Notifier).to receive(:ping)
    allow(SeasonBoard::Snapshot).to receive(:invalidate!)
    allow(PipelinePlannerJob).to receive(:enqueue_after)
    allow(ActionCable.server).to receive(:broadcast)
    crawler.statuses = [idle_status]
    crawler.after_pull = [idle_status, running_now, done_now]
  end

  after(:each) do
    described_class.sleeper = ->(seconds) { sleep(seconds) }
    described_class.crawler_client_factory = -> { CrawlerClient.new }
    described_class.launcher_factory = -> { CrawlerLauncher.new }
    described_class.data_dir = nil
    FileUtils.rm_rf(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'runs on the background queue with priority 10, without retry handlers' do
    job = described_class.new(kind: 'microplus', season_id:)
    expect(job.queue_name).to eq('background')
    expect(job.priority).to eq(10)
    expect(described_class.rescue_handlers).to be_empty
  end

  it 'shares the concurrency key AND group with the board crawls and extractions' do
    key = described_class.new(kind: 'microplus', season_id:).concurrency_key
    expect(key).to eq(MeetingCrawlJob.new(season_id: 262, fin_event_id: '1', url: 'x').concurrency_key)
    expect(key).to eq(ManifestExtractJob.new(season_id: 262, fin_event_id: '1').concurrency_key)
    expect(key).to eq('SeasonBoardBackground/season_board')
    expect(described_class.concurrency_limit).to eq(1)
  end

  context 'with a Microplus meeting' do
    before(:each) { crawler.on_pull = -> { write_result('2025-06-24-Riccione-lt4.json') } }

    it 'crawls it, lists the new file, closes the activity as done and announces it' do
      req = request
      perform(req)

      expect(crawler.calls).to eq([[:pull_microplus, { season_id:, url: microplus_url, target_event: nil }]])
      entry = activity_log.entry(req.key, :crawl)
      expect(entry).to have_attributes(status: :done, origin: :manual, label: req.label, url: microplus_url)
      expect(entry.message).to include('2025-06-24-Riccione-lt4.json')
      expect(ActionCable.server).to have_received(:broadcast).with(
        AppNotificationsChannel::STREAM,
        hash_including(dom_id: "sources-crawl-#{req.key.delete_prefix('src:')}", html: include('2025-06-24-Riccione-lt4.json'))
      )
      expect(SeasonBoard::Notifier).to have_received(:ping)
      expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(season_id)
    end

    it 'records the sources.crawl_finished event with the new files and a link to them' do
      req = request
      perform(req)
      event = Ops::Event.where(kind: 'sources.crawl_finished').last
      expect(event).to have_attributes(level: 'success', subject_key: req.key)
      expect(event.link_path).to start_with('/sources/results')
      expect(event.data['files']).to eq(['2025-06-24-Riccione-lt4.json'])
    end

    it 'passes the target event filter and does not pause after a non-FIN crawl' do
      perform(request(target_event: '200 Misti'))
      expect(crawler.calls.first.last).to include(target_event: '200 Misti')
      expect(slept).not_to include(described_class::PAUSE_AFTER_CRAWL)
    end
  end

  # 0.10.99: the board rows' "last crawl" badge reads the FIN id entries, not the 'src:' one.
  it 'records a done crawl entry under each FIN id of the new LT2 result files only, skipping an id with a busy crawl' do
    fin_url = ->(id) { "https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/#{id}:x.html" }
    crawler.on_pull = lambda {
      dir = data_root.join('results.new', season_id.to_s)
      FileUtils.mkdir_p(dir)
      File.write(dir.join('a.json'), { 'layoutType' => 2, 'meetingURL' => fin_url.call('150091') }.to_json)
      File.write(dir.join('b.json'), { 'layoutType' => 2, 'meetingURL' => fin_url.call('150092') }.to_json)
      File.write(dir.join('c-lt4-phase1.json'), { 'meetingURL' => fin_url.call('150093') }.to_json)
      # (a working copy and an LT4-content file rewritten meanwhile, e.g. by a prepare on the pipeline queue)
      File.write(dir.join('d-lt4.json'), { 'layoutType' => 4, 'meetingURL' => fin_url.call('150095') }.to_json)
      File.write(dir.join('e.json'), { 'layoutType' => 4, 'meetingURL' => fin_url.call('150096') }.to_json)
      FileUtils.mkdir_p(data_root.join('calendar.new', season_id.to_s))
      File.write(data_root.join('calendar.new', season_id.to_s, 'cal.csv'), "x;#{fin_url.call('150094')}\n")
    }
    activity_log.queue!('150092', kind: :crawl, origin: :auto)
    req = request
    perform(req)

    expect(activity_log.reload!.entry('150091', :crawl)).to have_attributes(status: :done, origin: :manual, message: req.label)
    expect(activity_log.entry('150092', :crawl)).to be_queued
    expect(activity_log.entry('150093', :crawl)).to be_nil
    expect(activity_log.entry('150094', :crawl)).to be_nil
    expect(activity_log.entry('150095', :crawl)).to be_nil
    expect(activity_log.entry('150096', :crawl)).to be_nil
    expect(activity_log.entry(req.key, :crawl)).to be_done
  end

  it 'records no FIN entry for a failed crawl' do
    crawler.pull_result = CrawlerClient::Result.new(ok: false, code: 400, body: nil, error: 'Missing season_id')
    perform
    expect(activity_log.all_entries.map(&:fin_event_id)).to all(start_with('src:'))
  end

  it 'waits while the crawler is busy with another crawl, then starts' do
    crawler.statuses = [running_now, running_now, idle_status]
    perform
    expect(crawler.calls.size).to eq(1)
    expect(slept.first(2)).to eq([Crawler::RunWatcher::POLL_INTERVAL] * 2)
  end

  it 'gives up when the crawler stays busy past the idle wait' do
    crawler.statuses = [running_now]
    req = request
    perform(req)
    expect(crawler.calls).to be_empty
    expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :failed, message: start_with('crawler busy with another crawl'))
    expect(Ops::Event.where(kind: 'sources.crawl_failed', subject_key: req.key)).to exist
  end

  it 'fails (without raising) when the crawler server is unreachable or cannot be started' do
    crawler.statuses = [nil]
    req = request
    expect { perform(req) }.not_to raise_error
    expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :failed, message: 'crawler server unreachable')
    allow(launcher).to receive(:ensure_running!).and_return(:failed)
    perform(req)
    expect(activity_log.reload!.entry(req.key, :crawl).message).to start_with('crawler server cannot be started')
    expect(crawler.calls).to be_empty
  end

  it 'refuses an invalid request without calling the crawler' do
    req = request(url: 'https://example.com/x.php')
    perform(req)
    expect(crawler.calls).to be_empty
    expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :failed, message: start_with('refused:'))
  end

  it 'reports a crawler API failure' do
    crawler.pull_result = CrawlerClient::Result.new(ok: false, code: 400, body: nil, error: 'Missing season_id')
    req = request
    perform(req)
    expect(activity_log.entry(req.key, :crawl).message).to include('Missing season_id')
  end

  it 'reports a crawler error status as a failure' do
    crawler.after_pull = [idle_status, ->(now) { { 'timestamp' => ts(now), 'status' => 'ERROR', 'detail' => 'page not found' } }]
    req = request
    perform(req)
    expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :failed, message: 'crawler error: page not found')
  end

  describe 'a calendar CSV crawl (several meetings)' do
    let(:csv_dir) { data_root.join('calendar.new', season_id.to_s) }
    let(:csv_path) { csv_dir.join('cal.csv') }
    let(:req) { request(kind: 'calendar_results', url: nil, file_path: csv_path.realpath.to_s) }

    before(:each) do
      FileUtils.mkdir_p(csv_dir)
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv_path)
    end

    it 'uses the season result layout, a timeout per meeting, and pauses after the FIN crawl' do
      perform(req)
      expect(crawler.calls).to eq([[:pull_results_from_file, { season_id:, file_path: csv_path.realpath.to_s, layout: 2 }]])
      expect(req.timeout).to eq(10 * 30.minutes)
      expect(slept.last).to eq(described_class::PAUSE_AFTER_CRAWL)
    end

    it 'keeps the activity busy past 40 minutes through the heartbeat' do
      started = Time.current
      busy_late = []
      crawler.after_pull = [idle_status, lambda { |now|
        if now > started + 45.minutes
          busy_late << SeasonBoard::ActivityLog.new.busy?(req.key, kind: :crawl)
          done_now.call(now)
        else
          running_now.call(now)
        end
      }]
      perform(req)
      expect(busy_late).to eq([true])
      expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :done)
      expect(activity_log.entry(req.key, :crawl).heartbeat_at).to be_present
    end
  end

  # 0.10.104: the tidy-up hook (Sources::CrawlTidy) after a crawl ended done.
  describe 'the clean-up after the crawl' do
    let(:fin_url) { "#{Sources::CrawlKinds::FIN_RESULTS_BASE_URL}150091:trofeo.html" }
    let(:req) { request(kind: 'fin_meeting', url: fin_url) }
    let(:lt2_path) { data_root.join('results.new', season_id.to_s, 'trofeo.json') }
    let(:calendar) do
      meeting = SeasonBoard::DbIndex::MeetingInfo.new(id: 19_000, description: 'M', code: 'm', header_date: nil, cancelled: false,
                                                      results_acquired: false, manifest: true, mir_count: 0, mrr_count: 0)
      SeasonBoard::DbIndex::CalendarInfo.new(id: 1700, fin_event_id: '150091', meeting_id: 19_000, meeting_code: 'm', meeting_name: 'M',
                                             meeting_place: 'X', scheduled_date: '8', year: '2026', month: 'Nov', cancelled: false,
                                             results_link: nil, meeting:)
    end

    before(:each) do
      allow(SeasonBoard::DbIndex).to receive(:new).and_return(instance_double(SeasonBoard::DbIndex, calendar_for: calendar))
      allow(SystemStatus::CrawlerProbe).to receive(:status_path).and_return(data_root.join('no-crawler-status.json'))
      path = lt2_path
      crawler.on_pull = lambda {
        FileUtils.mkdir_p(path.dirname)
        File.write(path, { 'layoutType' => 2, 'name' => 'Trofeo', 'meetingURL' => fin_url, 'sections' => [] }.to_json)
      }
    end

    it 'moves the result-free crawl of an already linked meeting to the backup folder and says so in the end message' do
      perform(req)
      entry = activity_log.reload!.entry(req.key, :crawl)
      expect(entry.status).to eq(:done)
      folder = Dir.children(data_root.join('results.backup', season_id.to_s)).first
      expect(entry.message).to include(I18n.t('sources.cleanup.crawl_summary.moved', count: 1, folder: "results.backup/#{season_id}/#{folder}"))
      expect(File).not_to exist(lt2_path)
      expect(Dir.glob(data_root.join('results.backup', season_id.to_s, 'cleanup-*', 'trofeo.json').to_s).size).to eq(1)
      data = Ops::Event.where(kind: 'sources.crawl_finished', subject_key: req.key).last.data
      expect(data['message']).to include('results.backup')
      expect(data['cleanup']).to eq('backup_dir' => "results.backup/#{season_id}/#{folder}", 'moves' => 1)
    end

    it 'never fails the crawl when the clean-up raises' do
      allow(Sources::CrawlTidy).to receive(:new).and_raise(Errno::EACCES, 'denied')
      perform(req)
      entry = activity_log.reload!.entry(req.key, :crawl)
      expect(entry).to have_attributes(status: :done, message: include('trofeo.json'))
      expect(File).to exist(lt2_path)
      expect(Ops::Event.where(kind: 'sources.crawl_finished', subject_key: req.key).last.data).not_to have_key('cleanup')
    end
  end

  # 0.10.103: the automatic 'Eventi' calendar crawl (SeasonBoard::Scheduler.calendar_crawl!) and the calendar checks.
  describe 'a FIN calendar crawl' do
    let(:req) { request(kind: 'calendar', url: nil, sub_menu_type: 'Eventi', year_text: '2025/2026') }
    let(:calendar_dir) { data_root.join('calendar.new', season_id.to_s) }
    let(:csv_name) { "#{Date.current.strftime('%Y%m%d')}-#{season_id}-2-FIN-calendar.csv" }

    def perform_calendar(origin: nil)
      args = { **req.to_job_args, key: req.key, label: req.label }
      args[:origin] = origin if origin
      described_class.perform_now(**args)
    end

    def write_calendar(rows: true)
      FileUtils.mkdir_p(calendar_dir)
      text = file_fixture('files/calendar_sample.csv').read
      File.write(calendar_dir.join(csv_name), rows ? text : text.lines.first)
    end

    def toasts
      calls = []
      allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| calls << payload }
      yield
      calls.select { |payload| payload[:dom_id].to_s.start_with?(described_class::TOAST_DOM_ID_PREFIX) }
    end

    it 'ends done with the new calendar file, as before (operator)' do
      crawler.on_pull = -> { write_calendar }
      perform_calendar
      expect(crawler.calls.first.first).to eq(:pull_calendar)
      expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :done, origin: :manual, message: include(csv_name))
      expect(Ops::Event.where(kind: 'sources.crawl_finished').last).to have_attributes(level: 'success')
      expect(Ops::Event.where(kind: 'sources.crawl_finished').last.data).to include('origin' => 'operator')
    end

    context 'when queued by the automation (origin auto)' do
      before(:each) { activity_log.queue!(req.key, kind: :crawl, origin: :auto, url: req.target, label: req.label) }

      it 'crawls with the switch on, records its origin and sends no toast' do
        crawler.on_pull = -> { write_calendar }
        expect(toasts { perform_calendar(origin: 'auto') }).to be_empty
        expect(activity_log.reload!.entry(req.key, :crawl)).to have_attributes(status: :done, origin: :auto)
        expect(Ops::Event.where(kind: 'sources.crawl_finished').last.data).to include('origin' => 'auto')
        expect(PipelinePlannerJob).to have_received(:enqueue_after).with('SourceCrawlJob')
      end

      it "refuses at start with the 'auto_calendar' switch off (or the master one), closing its queued entry" do
        DataFix::Automation.store!(:auto_calendar, false)
        perform_calendar(origin: 'auto')
        expect(crawler.calls).to be_empty
        expect(activity_log.reload!.entry(req.key, :crawl))
          .to have_attributes(status: :failed, message: I18n.t('pipeline_automation.reasons.automation_paused'))
        DataFix::Automation.store!(:auto_calendar, true)
        allow(DataFix::Automation).to receive(:env_off?).and_return(true)
        perform_calendar(origin: 'auto')
        expect(crawler.calls).to be_empty
      end

      it 'fails when the crawl brought no new calendar file (an empty or unsupported FIN page)' do
        perform_calendar(origin: 'auto')
        expect(activity_log.reload!.entry(req.key, :crawl))
          .to have_attributes(status: :failed, message: I18n.t('sources.crawl.calendar_check.no_file'))
        expect(Ops::Event.where(kind: 'sources.crawl_failed').last).to have_attributes(level: 'error')
      end

      it 'fails when the new calendar has no data rows' do
        crawler.on_pull = -> { write_calendar(rows: false) }
        perform_calendar(origin: 'auto')
        expect(activity_log.reload!.entry(req.key, :crawl)).to have_attributes(status: :failed, message: include(csv_name))
      end

      it 'refuses any other kind' do
        microplus = request
        described_class.perform_now(**microplus.to_job_args, key: microplus.key, label: microplus.label, origin: 'auto')
        expect(crawler.calls).to be_empty
        expect(activity_log.entry(microplus.key, :crawl).message).to eq(I18n.t('sources.crawl.auto_kind_refused', kind: 'microplus'))
      end
    end

    it 'ends done with a warning (warning toast and event) for an operator crawl that brought no usable calendar' do
      sent = toasts { perform_calendar }
      expect(activity_log.entry(req.key, :crawl)).to have_attributes(status: :done, message: I18n.t('sources.crawl.calendar_check.no_file'))
      expect(Ops::Event.where(kind: 'sources.crawl_finished').last).to have_attributes(level: 'warning')
      expect(sent.size).to eq(1)
      expect(sent.first[:html]).to include('text-bg-warning')
    end
  end
end
