# frozen_string_literal: true

require 'rails_helper'
require 'csv'

# 0.10.103, end to end at the service level (the crawler is a fake, the jobs run inline when the example says so; every
# file lives under a temporary data root): a FIN change adds a meeting without a link -> the 'Eventi' calendar crawl is
# queued -> its CSV lends the link -> the meeting is crawled -> it is prepared -> the parity is reached -> the change is
# acknowledged and the alert cleared on every tab.
RSpec.describe 'FIN calendar automation chain' do # rubocop:disable RSpec/DescribeClass
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.create(:season, begin_date: Date.new(2026, 9, 1), end_date: Date.new(2027, 8, 31)) }
  let(:data_dir) { Pathname.new(Dir.mktmpdir('fin-calendar-chain')) }
  let(:season_dir) { season.id.to_s }
  let(:store) { FedernuotoWatch::StateStore.new }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:adopted_id) { '150112' }
  let(:linked) { (1..9).map { |day| [day, format('1500%02d', day)] } }
  let(:stream) { AppNotificationsChannel::STREAM }

  def results_url(fin_id)
    "https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/#{fin_id}:meeting.html"
  end

  def linked_rows
    linked.map do |day, id|
      { 'year' => '2026', 'date' => format('%02d/10', day), 'name' => "Riepilogo #{day}", 'place' => "City#{day}",
        'url' => results_url(id), 'info' => '', 'key' => "k-#{id}" }
    end
  end

  def cagliari_row
    { 'year' => '2026', 'date' => '22/11', 'name' => '9° Sardinia in Water', 'place' => 'Cagliari', 'url' => '', 'info' => '',
      'key' => '2026 | 22/11 | 9° Sardinia in Water | Cagliari' }
  end

  # The 'Eventi' calendar CSV the crawler writes: the linked meetings plus Cagliari with its link.
  def write_eventi_csv
    rows = linked.map { |day, id| [format('2026-10-%02d', day), "City#{day} (XX)", id] } + [['2026-11-22', 'Cagliari (CA)', adopted_id]]
    dir = data_dir.join('calendar.new', season_dir)
    FileUtils.mkdir_p(dir)
    File.write(dir.join("#{Date.current.strftime('%Y%m%d')}-#{season.id}-2-FIN-calendar.csv"), CSV.generate do |csv|
      csv << %w[startURL date isCancelled name place meetingUrl year]
      rows.each { |date, place, id| csv << [SeasonBoard::CalendarIndex::EVENTI_START_URL, date, 'false', 'Meeting', place, results_url(id), '2026'] }
    end)
  end

  # The crawl and the preparation of Cagliari: its LT2 with results, the LT4 working copy and the phase files, and a
  # "ready to commit" pipeline source with five fresh checks.
  def crawl_and_prepare_cagliari! # rubocop:disable Metrics/AbcSize
    dir = data_dir.join('results.new', season_dir)
    FileUtils.mkdir_p(dir)
    lt2 = { 'layoutType' => 2, 'name' => 'Meeting', 'meetingURL' => results_url(adopted_id),
            'sections' => [{ 'title' => '50 SL - M25', 'rows' => [{ 'name' => 'ROSSI MARIO', 'timing' => '30.12' }] }] }
    File.write(dir.join('cagliari.json'), lt2.to_json)
    File.write(dir.join('cagliari-lt4.json'), { 'layoutType' => 4, 'name' => 'Meeting', 'meetingURL' => results_url(adopted_id),
                                                'events' => [{ 'eventCode' => '50SL', 'results' => [{}] }] }.to_json)
    (1..5).each { |phase| File.write(dir.join("cagliari-lt4-phase#{phase}.json"), '{}') }
    activity_log.reload!.start!(adopted_id, kind: :crawl)
    activity_log.finish!(adopted_id, kind: :crawl, status: :done)
    source = FactoryBot.create(:ops_pipeline_source, season_id: season.id, base: 'cagliari', source_path: dir.join('cagliari-lt4.json').to_s,
                                                     stage: 'ready_to_commit', db_generation: DataFix::Pipeline.db_generation)
    (1..5).each { |phase| FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, checked_at: 2.seconds.from_now) }
  end

  def fake_crawler(on_pull)
    Class.new do
      define_method(:status) { { 'timestamp' => Time.current.utc.strftime('%Y%m%d-%H%M%S'), 'status' => 'OK, done, idle', 'detail' => 'Done.' } }
      define_method(:pull_calendar) do |**_args|
        on_pull.call
        CrawlerClient::Result.new(ok: true, code: 200, body: {}, error: nil)
      end
    end.new
  end

  before(:each) do
    # (private state files: a suite running in parallel shares the default test ones)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_dir)
    allow(FedernuotoWatch::StateStore).to receive(:default_path).and_return(data_dir.join('federnuoto-watch.json'))
    allow(SeasonBoard::ActivityLog).to receive(:default_path).and_return(data_dir.join('season-board.json'))
    store.update do
      { 'digest' => 'd2', 'ack_digest' => 'd1', 'rows' => linked_rows + [cagliari_row], 'ack_rows' => linked_rows,
        'last_checked' => Time.current.iso8601,
        'change' => FedernuotoWatch::Checker.diff(linked_rows, linked_rows + [cagliari_row])
                                            .merge('detected_at' => 1.minute.ago.iso8601, 'first_detected_at' => 1.minute.ago.iso8601) }
    end
    SourceCrawlJob.data_dir = data_dir
    SourceCrawlJob.sleeper = ->(_seconds) {}
    SourceCrawlJob.launcher_factory = -> { instance_double(CrawlerLauncher, ensure_running!: :already_running) }
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  after(:each) do
    SourceCrawlJob.data_dir = nil
    SourceCrawlJob.sleeper = ->(seconds) { sleep(seconds) }
    SourceCrawlJob.crawler_client_factory = -> { CrawlerClient.new }
    SourceCrawlJob.launcher_factory = -> { CrawlerLauncher.new }
    FileUtils.rm_rf(data_dir)
  end

  it 'goes from the change to the acknowledged alert by itself, crawling only the changed meeting' do # rubocop:disable RSpec/MultipleExpectations
    # 1. A meeting without a link: no alert yet, the change waits for the 'Eventi' calendar crawl.
    expect(FedernuotoWatch::Parity.decision(store.pending_change, season:).first).to eq(:wait)

    # 2. The planner pass queues the automatic 'Eventi' calendar crawl (nothing else to crawl yet).
    outcome = SeasonBoard::ChangeChain.new(season:).call
    expect(outcome).to have_attributes(calendar: :queued, crawls: [])
    calendar_job = enqueued_jobs.find { |job| job['job_class'] == 'SourceCrawlJob' }
    expect(calendar_job).to be_present
    args = ActiveJob::Arguments.deserialize(calendar_job['arguments']).first.symbolize_keys
    expect(args).to include(kind: 'calendar', sub_menu_type: 'Eventi', origin: 'auto')

    # 3. The calendar crawl runs: its CSV lends Cagliari the link of the 'Eventi' calendar.
    SourceCrawlJob.crawler_client_factory = -> { fake_crawler(-> { write_eventi_csv }) }
    SourceCrawlJob.perform_now(**args)
    expect(activity_log.reload!.entry(args[:key], :crawl)).to have_attributes(status: :done, origin: :auto)

    # 4. The next pass crawls the adopted meeting only (the linked ones are not in the change).
    clear_enqueued_jobs
    outcome = SeasonBoard::ChangeChain.new(season:).call
    expect(outcome).to have_attributes(calendar: :crawled_since_change, crawls: [adopted_id])
    expect(MeetingCrawlJob).to have_been_enqueued.with(season_id: season.id, fin_event_id: adopted_id, url: results_url(adopted_id), origin: 'auto')
    expect(enqueued_jobs.count { |job| job['job_class'] == 'MeetingCrawlJob' }).to eq(1)

    # 5. While it is crawled the alert shows, with the progress.
    expect { FedernuotoWatch::ParityCheck.call(season:) }.to have_broadcasted_to(stream).with(
      a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID, html: a_string_including('federnuoto-watch-progress'))
    )
    expect(FedernuotoWatch::Progress.read('d2')).to include('actionable' => 1, 'reached' => false)

    # 6. Crawled and prepared ("ready to commit"): the parity is reached, the change acknowledged, the alert cleared.
    crawl_and_prepare_cagliari!
    expect(SeasonBoard::Snapshot.fetch(season).row_for(adopted_id)).to have_attributes(state: :ready_to_commit)
    outcome = nil
    expect { outcome = FedernuotoWatch::ParityCheck.call(season:) }
      .to have_broadcasted_to(stream).with(dom_id: FedernuotoWatch::ALERT_DOM_ID, html: '')
    expect(outcome.status).to eq(:acknowledged)
    expect(store.pending_change).to be_nil
    expect(store.read['ack_digest']).to eq('d2')
    expect(Ops::Event.find_by(kind: 'fin.watch_acknowledged').data).to include('actor' => 'auto', 'reason' => 'parity')
  end

  describe 'the fail-closed paths' do
    def alert_html = ApplicationController.render(FedernuotoWatchAlertComponent.from_store(store), layout: false)

    it 'with the master switch off: nothing queued, nothing acknowledged, the alert shown (through the watcher job)' do
      DataFix::Automation.store!(:enabled, false)
      allow(FedernuotoWatch::Checker).to receive(:call).and_return(:changed)
      expect(SeasonBoard::ChangeChain.new(season:).call).to have_attributes(calendar: :paused, crawls: [], recrawls: [])
      allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
      expect { FedernuotoWatchJob.perform_now }.not_to have_enqueued_job
      expect(store.pending_change).to be_present
      expect(Ops::Event.where(kind: %w[fin.watch_acknowledged fin.calendar_notice])).to be_empty
      expect(FedernuotoWatch::Progress.read('d2')).to include('automation' => false)
      expect(alert_html).to include(FedernuotoWatch::ALERT_DOM_ID, '9° Sardinia in Water')
      expect(FedernuotoWatch::Parity.decision(store.pending_change, season:).first).to eq(:alert)
    end

    it 'without the ops DB: the alert, never an acknowledge (no trace could be written)' do
      allow(Ops).to receive(:available?).and_return(false)
      expect(FedernuotoWatch::Parity.decision(store.pending_change, season:).first).to eq(:alert)
      expect(FedernuotoWatch::ParityCheck.call(season:).status).not_to eq(:acknowledged)
      expect(store.pending_change).to be_present
    end

    it 'with the events not writable (a locked ops DB): the change stays pending and the alert shows' do
      DataFix::Automation.store!(:auto_calendar, false) # (Cagliari has nothing to crawl: a notice)
      allow(Ops::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(FedernuotoWatch::ParityCheck.call(season:).status).to eq(:stale)
      expect(store.pending_change).to be_present
      expect(alert_html).to include(FedernuotoWatch::ALERT_DOM_ID)
    end

    it 'a change waiting for the Eventi calendar becomes an acknowledge and a notice once the wait expires' do
      outcome = FedernuotoWatch::ParityCheck.call(season:)
      expect(outcome.status).to eq(:pending)
      expect(outcome.parity.awaiting_calendar.map(&:key)).to eq([cagliari_row['key']])
      expect(alert_html).not_to include(FedernuotoWatch::ALERT_DOM_ID)
      travel(FedernuotoWatch::Parity::CALENDAR_WAIT + 1.minute) do
        expect(FedernuotoWatch::ParityCheck.call(season:).status).to eq(:acknowledged)
      end
      notice = Ops::Event.find_by(kind: 'fin.calendar_notice')
      expect(notice.data['without_link'].pluck('name')).to eq(['9° Sardinia in Water'])
      expect(store.pending_change).to be_nil
    end
  end
end
