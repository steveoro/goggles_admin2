# frozen_string_literal: true

require 'rails_helper'

# 0.10.99: SeasonBoard::ActivityReconciler::QueueProbe against real Solid Queue tables. The test env runs Active Job on
# the :test adapter and SolidQueue::Record has no database of its own, so each example points SolidQueue::Record at a
# private SQLite file loaded with db/queue_schema.rb (never the shared MySQL test DB), and enqueues real jobs through
# SolidQueue::Job.enqueue (the adapter's own path: ready, blocked by a concurrency key, scheduled), plus a claimed, a
# failed and a finished one.
RSpec.describe SeasonBoard::ActivityReconciler::QueueProbe do
  let(:classes) { SeasonBoard::ActivityReconciler::JOB_CLASSES.values.flatten }
  let(:pdf) { '/data/manifests/262/manifest-x.pdf' }

  # Runs the create_table / add_foreign_key statements of db/queue_schema.rb on +connection+.
  def load_queue_schema(connection)
    body = Rails.root.join('db/queue_schema.rb').read[/\.define\(version: [\d_]+\) do\n(.*)^end/m, 1]
    raise 'unreadable db/queue_schema.rb' if body.blank?

    connection.instance_eval(body)
  end

  def enqueue(job, scheduled_at: Time.current) = SolidQueue::Job.enqueue(job, scheduled_at:)

  # (once per group, so the file outlives the fixture transaction of each example, which rolls back its rows on this
  # pool too; per example, the teardown would reopen a removed file)
  # rubocop:disable RSpec/BeforeAfterAll, RSpec/InstanceVariable
  before(:context) do
    @queue_dir = Dir.mktmpdir('queue-probe')
    SolidQueue::Record.establish_connection(adapter: 'sqlite3', database: File.join(@queue_dir, 'queue.sqlite3'))
    load_queue_schema(SolidQueue::Record.connection)
  end

  after(:context) do
    SolidQueue::Record.remove_connection # (back on the primary pool, as before)
    FileUtils.rm_rf(@queue_dir)
  end
  # rubocop:enable RSpec/BeforeAfterAll, RSpec/InstanceVariable

  before(:each) { allow(Dashboard::QueueActivity).to receive(:solid_queue?).and_return(true) }

  it 'keeps the keys of the ready, blocked, scheduled and claimed jobs, never the failed or finished ones' do
    ready = enqueue(DataFixPrepareJob.new(source_path: '/x-lt4.json', season_id: 262, origin: 'auto', fin_event_id: '150001', run_id: 1))
    blocked = enqueue(DataFixPrepareJob.new(source_path: '/y-lt4.json', season_id: 262, origin: 'auto', fin_event_id: '150002', run_id: 2))
    scheduled = enqueue(MeetingCrawlJob.new(season_id: 262, fin_event_id: '150003', url: 'https://x'), scheduled_at: 1.hour.from_now)
    claimed = enqueue(ManifestExtractJob.new(season_id: 262, pdf_path: pdf))
    failed = enqueue(SourceCrawlJob.new(kind: 'microplus', season_id: 262, key: 'src:failed', url: 'https://y'))
    finished = enqueue(MeetingCrawlJob.new(season_id: 262, fin_event_id: '150006', url: 'https://z'))
    other = enqueue(KpiRefreshJob.new)

    expect(SolidQueue::ReadyExecution.where(job_id: ready.id)).to exist
    expect(SolidQueue::BlockedExecution.where(job_id: blocked.id)).to exist
    expect(SolidQueue::ScheduledExecution.where(job_id: scheduled.id)).to exist
    process = SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: Time.current, pid: 1, hostname: 'spec', name: 'spec-worker')
    SolidQueue::ReadyExecution.where(job_id: claimed.id).delete_all
    SolidQueue::ClaimedExecution.create!(job_id: claimed.id, process_id: process.id)
    SolidQueue::ReadyExecution.where(job_id: failed.id).delete_all
    SolidQueue::FailedExecution.create!(job_id: failed.id, exception: RuntimeError.new('boom'))
    finished.update!(finished_at: Time.current)
    expect(other).to be_persisted

    expect(described_class.new.live_keys(classes))
      .to eq(Set['150001', '150002', '150003', SeasonBoard::ActivityLog.source_key('extract', pdf)])
    expect(described_class.new.live_keys(%w[DataFixPrepareJob])).to eq(Set['150001', '150002'])
  end

  it 'reads the arguments whether the column comes back type cast (Hash) or raw (JSON String)' do
    job = enqueue(SourceCrawlJob.new(kind: 'microplus', season_id: 262, key: 'src:abc', url: 'https://y'))
    expect(SolidQueue::Job.where(id: job.id).pick(:arguments)).to be_a(Hash)
    raw = SolidQueue::Record.connection.select_value("SELECT arguments FROM solid_queue_jobs WHERE id = #{job.id.to_i}")
    expect(raw).to be_a(String)
    expect(described_class.key_for('SourceCrawlJob', raw)).to eq('src:abc')
    expect(described_class.new.live_keys(%w[SourceCrawlJob])).to eq(Set['src:abc'])
  end

  it 'answers ANY_KEY for a prepare queued before 0.10.99 (no FIN id in its arguments)' do
    enqueue(DataFixPrepareJob.new(source_path: '/x-lt4.json', season_id: 262, origin: 'auto', run_id: 1))
    expect(described_class.new.live_keys(%w[DataFixPrepareJob])).to eq(Set[SeasonBoard::ActivityReconciler::ANY_KEY])
  end

  it 'lets the reconciler close a queued entry without job and keep the one whose job is scheduled' do
    log = SeasonBoard::ActivityLog.new
    FileUtils.rm_f(log.path)
    allow(SeasonBoard::Notifier).to receive(:ping)
    enqueue(MeetingCrawlJob.new(season_id: 262, fin_event_id: '150003', url: 'https://x'), scheduled_at: 1.hour.from_now)
    log.queue!('150003', kind: :crawl, origin: :auto)
    log.queue!('150009', kind: :crawl, origin: :auto)
    closed = SeasonBoard::ActivityReconciler.new(activity_log: log, now: 10.minutes.from_now).call
    expect(closed.map(&:key)).to eq(['150009'])
    expect(log.reload!.entry('150003', :crawl)).to be_queued
  ensure
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'answers nil (the lost rule is skipped) when the queue tables cannot be read' do
    allow(SolidQueue::Job).to receive(:where).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
    expect(described_class.new.live_keys(classes)).to be_nil
  end
end
