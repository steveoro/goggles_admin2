# frozen_string_literal: true

require 'rails_helper'

# 0.10.99: the board activity entries a job could not close (the "prepare queued" phantoms of 2026-11-25, a job lost
# from the queue) are closed by the reconciler at the top of every planner pass.
RSpec.describe SeasonBoard::ActivityReconciler do
  include ActiveSupport::Testing::TimeHelpers

  let(:log) { SeasonBoard::ActivityLog.new }
  let(:now) { Time.zone.parse('2026-11-26 10:00') }
  # Fake queue: the Set of keys of the unfinished jobs (nil: unreadable queue).
  let(:live) { Set.new }
  let(:probe) do
    keys = live
    Class.new { define_method(:live_keys) { |_class_names| keys } }.new
  end

  def reconcile(queue_probe: probe) = described_class.new(activity_log: log, queue_probe:, now:).call

  def queue_at(time, key, kind: :prepare, **options)
    travel_to(time) { log.queue!(key, kind:, origin: :auto, **options) }
  end

  def run!(status:, created_at:, finished_at: nil, source: nil, message: nil)
    FactoryBot.create(:ops_pipeline_run, kind: 'prepare', origin: 'auto', status:, pipeline_source: source, subject_key: source&.base || 'm',
                                         created_at:, finished_at:, message:)
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  # The live shape of 2026-11-25: five automatic prepares queued at 11:14:37Z without run id nor FIN id in the job;
  # the jobs ran and closed their runs 'done' (11:15-11:18), the source rows got their FIN id, the entries stayed queued.
  it 'repairs the five phantom "prepare queued" entries of the live log on the first pass (no queue needed)' do
    live_rows = {
      '150092' => ['2026-10-25-25°_Trofeo_Città_di_Verolanuova', 'Preparato: Da rivedere', '11:15:23'],
      '150094' => ['2026-11-08-21°_Meeting_della_Solidarieta', 'Preparato: Pronta per il commit', '11:15:54'],
      '150093' => ['2026-11-08-Trofeo_Lalla_Cecchi', 'Preparato: Bloccata', '11:16:07'],
      '150096' => ['2026-11-08-17°_Trofeo_Cittadi_Saronno', 'Preparato: Bloccata', '11:17:32'],
      '150097' => ['2026-11-08-2°_Trofeo_Sporting', 'Preparato: Da rivedere', '11:18:06']
    }
    entries = live_rows.keys.index_with do
      { 'prepare' => { 'origin' => 'auto', 'status' => 'queued', 'queued_at' => '2026-11-25T11:14:37Z', 'started_at' => nil,
                       'finished_at' => nil, 'url' => nil, 'message' => nil } }
    end
    File.write(SeasonBoard::ActivityLog.default_path, JSON.generate('entries' => entries))
    live_rows.each_with_index do |(fin_id, (base, message, finished)), index|
      source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base:, fin_event_id: fin_id, stage: 'needs_review')
      run!(status: 'done', source:, message:, created_at: Time.utc(2026, 11, 25, 11, 14, 37) + (index * 0.02),
           finished_at: Time.zone.parse("2026-11-25 #{finished}Z"))
    end
    expect(log.all_entries.map(&:status).uniq).to eq([:queued])

    closed = reconcile(queue_probe: Class.new { def live_keys(_names) = nil }.new)
    expect(closed.map(&:key)).to match_array(live_rows.keys)
    expect(closed.map(&:status).uniq).to eq([:done])
    live_rows.each do |fin_id, (_base, message, _finished)|
      expect(log.reload!.entry(fin_id, :prepare)).to have_attributes(status: :done, message:, finished_at: be_present)
      expect(log.busy?(fin_id, now:)).to be false
    end
    expect(SeasonBoard::Notifier).to have_received(:ping).once
    expect(reconcile).to eq([]) # (nothing left to close on the next pass)
  end

  it 'closes a prepare entry from its finished run (run id): refused / failed => failed, yielded => done' do
    { 'refused' => :failed, 'failed' => :failed, 'yielded' => :done, 'done' => :done }.each_with_index do |(status, expected), index|
      key = "15010#{index}"
      run = run!(status:, created_at: now - 1.hour, finished_at: now - 50.minutes, message: "run #{status}")
      queue_at(now - 1.hour, key, run_id: run.id)
      travel_to(now - 55.minutes) { log.start!(key, kind: :prepare) } if index.even?
      expect(reconcile.map(&:key)).to eq([key])
      expect(log.reload!.entry(key, :prepare)).to have_attributes(status: expected, message: "run #{status}", run_id: run.id)
    end
  end

  it 'leaves a prepare entry alone while its run is pending and its job is in the queue' do
    run = run!(status: 'queued', created_at: now - 10.minutes)
    queue_at(now - 10.minutes, '150091', run_id: run.id)
    live << '150091'
    expect(reconcile).to eq([])
    expect(log.reload!.entry('150091', :prepare)).to be_queued
  end

  describe 'a queued entry whose job is no longer in the queue' do
    it 'is closed as failed, reason lost, after the grace period; its queued run is closed refused' do
      run = run!(status: 'queued', created_at: now - 10.minutes)
      queue_at(now - 10.minutes, '150091', run_id: run.id)
      closed = reconcile
      expect(closed).to eq([described_class::Closed.new(key: '150091', kind: :prepare, status: :failed, reason: 'lost')])
      entry = log.reload!.entry('150091', :prepare)
      expect(entry).to have_attributes(status: :failed, reason: 'lost', message: I18n.t('season_board.activity.lost_message'))
      expect(entry).to be_lost
      expect(run.reload).to have_attributes(status: 'refused', error: start_with('lost: '))
    end

    it 'applies to every kind (a crawl, a Sources extraction), checking the job of its own key' do
      queue_at(now - 10.minutes, '150091', kind: :crawl)
      queue_at(now - 10.minutes, '150092', kind: :crawl)
      src_key = SeasonBoard::ActivityLog.source_key('extract', '/m/manifest-x.pdf')
      queue_at(now - 10.minutes, src_key, kind: :extract)
      live << '150092'
      expect(reconcile.map { |row| [row.key, row.kind] }).to contain_exactly(['150091', :crawl], [src_key, :extract])
      expect(log.reload!.entry('150092', :crawl)).to be_queued
    end

    it 'is left alone within the grace period, with an unreadable queue, or when a job has no readable key' do
      queue_at(now - 1.minute, '150091', kind: :crawl)
      expect(reconcile).to eq([])
      queue_at(now - 10.minutes, '150091', kind: :crawl)
      expect(reconcile(queue_probe: Class.new { def live_keys(_names) = nil }.new)).to eq([])
      live << described_class::ANY_KEY
      expect(reconcile).to eq([])
      expect(log.reload!.entry('150091', :crawl)).to be_queued
    end

    it 'never closes an attempt that changed meanwhile (compare-and-set)' do
      queue_at(now - 10.minutes, '150091', kind: :crawl)
      read_before = log.all_entries
      log.start!('150091', kind: :crawl)
      allow(log).to receive(:all_entries).and_return(read_before)
      expect(reconcile).to eq([])
      expect(log.reload!.entry('150091', :crawl)).to be_running
    end
  end

  it 'never touches done or failed entries' do
    queue_at(now - 2.days, '150091', kind: :crawl)
    log.finish!('150091', kind: :crawl, status: :done)
    expect(reconcile).to eq([])
  end

  it 'never raises: an unreadable ops DB skips the run rule, an unreadable log skips the pass' do
    queue_at(now - 10.minutes, '150091', run_id: 1)
    live << '150091'
    allow(Ops::PipelineRun).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
    expect(reconcile).to eq([])
    allow(log).to receive(:all_entries).and_raise(Errno::EACCES)
    expect(reconcile).to eq([])
  end

  describe SeasonBoard::ActivityReconciler::QueueProbe do
    def payload(**args) = { 'job_class' => 'X', 'arguments' => [args.stringify_keys.merge('_aj_ruby2_keywords' => args.keys.map(&:to_s))] }

    it 'reads the activity key from the serialized job arguments (Hash or JSON)' do
      expect(described_class.key_for('DataFixPrepareJob', payload(source_path: '/x.json', fin_event_id: '150091'))).to eq('150091')
      expect(described_class.key_for('MeetingCrawlJob', payload(fin_event_id: '150092').to_json)).to eq('150092')
      expect(described_class.key_for('SourceCrawlJob', payload(kind: 'microplus', key: 'src:abc'))).to eq('src:abc')
      expect(described_class.key_for('ManifestExtractJob', payload(season_id: 262, pdf_path: '/m/manifest-x.pdf')))
        .to eq(SeasonBoard::ActivityLog.source_key('extract', '/m/manifest-x.pdf'))
    end

    it 'answers ANY_KEY for a job without a readable key (a prepare queued before 0.10.99), nil outside Solid Queue' do
      expect(described_class.key_for('DataFixPrepareJob', payload(source_path: '/x.json', fin_event_id: nil))).to eq(:any)
      expect(described_class.key_for('DataFixPrepareJob', 'not json')).to eq(:any)
      expect(described_class.new.live_keys(%w[DataFixPrepareJob])).to be_nil # (the test env uses the :test adapter)
    end
  end
end
