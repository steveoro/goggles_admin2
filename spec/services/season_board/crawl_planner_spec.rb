# frozen_string_literal: true

require 'rails_helper'
require_relative 'board_rows'

RSpec.describe SeasonBoard::CrawlPlanner do
  include SeasonBoardRows
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:rows) do
    [
      board_row(fin_event_id: '1', state: :link_not_crawled, action: :crawl),
      board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl),
      board_row(fin_event_id: '3', state: :structure_committed, action: :check_results),
      board_row(fin_event_id: '4', state: :link_not_crawled, action: :crawl)
    ]
  end
  let(:builder) { instance_double(SeasonBoard::Builder, call: board_result(rows)) }

  def change_for(*fin_ids, key: 'added')
    { key => fin_ids.map { |id| { 'url' => rows.find { |row| row.fin_event_id == id }.url } }, 'removed' => [] }
  end

  def plan(change)
    described_class.new(season:, activity_log:, builder:).call(change)
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  it 'auto-crawls the changed :link_not_crawled rows only' do
    change = change_for('1', '3').merge('with_results' => change_for('2')['added'], 'updated' => [])
    expect(plan(change)).to eq(%w[1 2])
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '1', url: rows[0].url, origin: :auto)
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '2', url: rows[1].url, origin: :auto)
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).twice
  end

  it 'skips the rows whose date matches a local calendar not linked yet' do
    rows[1] = board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl, flags: [:possible_unlinked_meeting])
    expect(plan(change_for('1', '2'))).to eq(%w[1])
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).once
  end

  it 'stores its board build as the board summary' do
    plan(change_for('1'))
    expect(SeasonBoard::Snapshot.read(262).rows.map(&:fin_event_id)).to eq(%w[1 2 3 4])
  end

  it 'considers the updated rows too' do
    expect(plan(change_for('4', key: 'updated'))).to eq(%w[4])
  end

  it 'skips rows already attempted for the same URL (the change is cumulative)' do
    activity_log.queue!('1', kind: :crawl, origin: :auto, url: rows[0].url)
    activity_log.finish!('1', kind: :crawl, status: :done, message: 'no results yet')
    expect(plan(change_for('1', '2'))).to eq(%w[2])
  end

  it 'crawls again when the previous attempt was for a different URL' do
    activity_log.queue!('1', kind: :crawl, origin: :auto, url: 'https://www.federnuoto.it/old#/risultati/1:old.html')
    activity_log.finish!('1', kind: :crawl, status: :failed)
    expect(plan(change_for('1'))).to eq(%w[1])
  end

  it 'logs a failed enqueue and goes on with the remaining rows' do
    allow(SeasonBoard::Scheduler).to receive(:crawl!).with(hash_including(fin_event_id: '1')).and_raise(StandardError, 'queue DB missing')
    allow(Rails.logger).to receive(:error)
    expect(plan(change_for('1', '2'))).to eq(%w[2])
    expect(Rails.logger).to have_received(:error).with(/FIN 1.*queue DB missing/)
  end

  it 'omits rows refused by the Scheduler (busy)' do
    allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(false)
    expect(plan(change_for('1'))).to eq([])
  end

  it 'does nothing without a change, changed FIN ids or season' do
    expect(plan(nil)).to eq([])
    expect(plan('added' => [{ 'url' => '' }])).to eq([])
    expect(described_class.new(season: nil, activity_log:, builder:).call(change_for('1'))).to eq([])
    expect(builder).not_to have_received(:call)
  end

  it 'queues nothing with the automation master switch off (phase 10)' do
    DataFix::Automation.store!(:enabled, false)
    expect(plan(change_for('1', '2'))).to eq([])
    expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
  end

  describe 'new or changed meetings only (0.10.103)' do
    let(:adopted) { board_row(fin_event_id: '7', state: :link_not_crawled, action: :crawl, flags: [:link_adopted]) }

    it 'crawls a changed row without a link whose board row adopts one from the Eventi calendar (matched by key)' do
      rows << adopted
      expect(plan('added' => [{ 'key' => 'k-7', 'url' => '' }])).to eq(%w[7])
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '7', url: adopted.url, origin: :auto)
    end

    it 'never crawls an adopted row that is not in the change' do
      rows << adopted
      expect(plan(change_for('1'))).to eq(%w[1])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!).with(hash_including(fin_event_id: '7'))
    end

    it 'skips an adopted row whose unattended crawls gave up (3 failures in a row)' do
      rows << adopted
      3.times { Ops.record_event!(kind: 'board.crawl_failed', actor: 'job', subject_type: 'fin_event', subject_key: '7', data: { 'message' => 'x' }) }
      expect(plan('added' => [{ 'key' => 'k-7', 'url' => '' }])).to eq([])
    end

    it 'never crawls a row FIN removed from the page' do
      rows << board_row(fin_event_id: '8', state: :link_not_crawled, action: :crawl, flags: [:removed_from_fin])
      expect(plan('updated' => [{ 'key' => 'k-8', 'url' => rows.last.url }])).to eq([])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end

    it 'queues at most MAX_CRAWLS_PER_PASS crawls per pass, logging the ones left for the next pass' do
      many = (10..30).map { |id| board_row(fin_event_id: id.to_s, state: :link_not_crawled, action: :crawl) }
      rows.replace(many)
      allow(Rails.logger).to receive(:info)
      queued = plan('added' => many.map { |row| { 'key' => row.key, 'url' => row.url } })
      expect(queued).to eq((10..24).map(&:to_s))
      expect(Rails.logger).to have_received(:info).with(/left for a next pass: 25, 26, 27, 28, 29, 30/)
    end

    it 'does not count a refused (busy) row against the cap' do
      many = (10..26).map { |id| board_row(fin_event_id: id.to_s, state: :link_not_crawled, action: :crawl) }
      rows.replace(many)
      allow(SeasonBoard::Scheduler).to receive(:crawl!).with(hash_including(fin_event_id: '10')).and_return(false)
      expect(plan('added' => many.map { |row| { 'key' => row.key, 'url' => row.url } }).size).to eq(15)
    end
  end

  describe '#plan_recrawl (FIN now lists a structure-committed meeting with results)' do
    def recrawl(change)
      described_class.new(season:, activity_log:, builder:).plan_recrawl(change)
    end

    let(:with_results) { { 'with_results' => [{ 'url' => rows[2].url }, { 'url' => rows[0].url }] } }

    it 're-crawls only the :structure_committed rows listed under with_results, ignoring the same-URL dedupe' do
      activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
      activity_log.finish!('3', kind: :crawl, status: :done)
      Ops::Snapshot.delete_all
      travel_to(21.hours.from_now) do
        expect(recrawl(with_results)).to eq(%w[3])
        expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '3', url: rows[2].url, origin: :auto).once
      end
    end

    it 'crawls a row at most once per 20 hours' do
      activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
      activity_log.finish!('3', kind: :crawl, status: :done)
      expect(recrawl(with_results)).to eq([])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end

    it 'skips busy rows and queues nothing with the automation off' do
      rows[2] = board_row(fin_event_id: '3', state: :structure_committed, action: :check_results, busy: true)
      expect(recrawl(with_results)).to eq([])
      rows[2] = board_row(fin_event_id: '3', state: :structure_committed, action: :check_results)
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect(recrawl(with_results)).to eq([])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end

    describe "each row's own detection time (0.10.103)" do
      let(:detected) { 2.hours.ago }

      def with_results_for(*board_rows_of)
        { 'with_results' => board_rows_of.map { |row| { 'key' => row.key, 'url' => row.url } },
          'row_detected_at' => { 'with_results' => board_rows_of.to_h { |row| [row.key, detected.iso8601] } } }
      end

      it 're-crawls the rows whose source is not in review, whatever their state, never the ones in review' do
        rows.replace([board_row(fin_event_id: '5', state: :results_ready), board_row(fin_event_id: '6', state: :manifest_pending),
                      board_row(fin_event_id: '7', state: :needs_review), board_row(fin_event_id: '8', state: :ready_to_commit),
                      board_row(fin_event_id: '9', state: :committed_with_results)])
        expect(recrawl(with_results_for(*rows))).to eq(%w[5 6])
      end

      it 're-crawls a row crawled shortly BEFORE its results were published, not one crawled since' do
        travel_to(detected - 1.hour) do
          activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
          activity_log.finish!('3', kind: :crawl, status: :done)
        end
        expect(recrawl(with_results_for(rows[2]))).to eq(%w[3])
        activity_log.reload!.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
        activity_log.finish!('3', kind: :crawl, status: :done)
        expect(described_class.new(season:, activity_log: activity_log.reload!, builder:).plan_recrawl(with_results_for(rows[2]))).to eq([])
      end

      it 'retries a failed attempt since the detection only after 20 hours' do
        activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
        activity_log.finish!('3', kind: :crawl, status: :failed)
        expect(recrawl(with_results_for(rows[2]))).to eq([])
        travel(21.hours) { expect(recrawl(with_results_for(rows[2]))).to eq(%w[3]) }
      end
    end
  end

  describe 'the ceiling on outstanding automatic crawls (0.10.103: SeasonBoard::CrawlBudget)' do
    let(:many) { (10..30).map { |id| board_row(fin_event_id: id.to_s, state: :link_not_crawled, action: :crawl) } }
    let(:change) { { 'added' => many.map { |row| { 'key' => row.key, 'url' => row.url } } } }

    before(:each) { rows.replace(many) }

    it 'queues only what is left of the 15 automatic crawls queued or running (operator and Sources crawls not counted)' do
      %w[901 902 903 904 905 906 907 908 909 910].each { |id| activity_log.queue!(id, kind: :crawl, origin: :auto) }
      activity_log.queue!('911', kind: :crawl, origin: :manual)
      activity_log.queue!(SeasonBoard::ActivityLog.source_key('crawl:calendar', 'x'), kind: :crawl, origin: :auto)
      expect(SeasonBoard::CrawlBudget.outstanding(activity_log.reload!)).to eq(10)
      expect(plan(change).size).to eq(5)
    end

    it 'queues nothing while 15 are outstanding, and shares the budget with the re-crawls of the pass' do
      (1..15).each { |id| activity_log.queue!("90#{id}", kind: :crawl, origin: :auto) }
      expect(plan(change)).to eq([])
      activity_log.reload!.all_entries.first(3).each { |entry| activity_log.finish!(entry.fin_event_id, kind: :crawl, status: :done) }
      planner = described_class.new(season:, activity_log: activity_log.reload!, builder:)
      expect(planner.call(change).size).to eq(3)
      expect(planner.plan_recrawl({ 'with_results' => [{ 'key' => rows[0].key, 'url' => rows[0].url }] })).to eq([])
    end

    it 'counts a stale entry as no longer outstanding' do
      travel_to(13.hours.ago) { (1..15).each { |id| activity_log.queue!("90#{id}", kind: :crawl, origin: :auto) } }
      expect(SeasonBoard::CrawlBudget.remaining(activity_log.reload!)).to eq(15)
    end
  end
end
