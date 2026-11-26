# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::ActivityLog do
  include ActiveSupport::Testing::TimeHelpers

  subject(:log) { described_class.new(path: log_path) }

  let(:tmp_dir) { Dir.mktmpdir('season-board-log') }
  let(:log_path) { File.join(tmp_dir, 'nested', 'season-board.json') }
  let(:now) { Time.zone.parse('2026-11-12 10:00:00') }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it 'defaults to crawler/data/season-board.json (overridden in the test env)' do
    expect(described_class::DEFAULT_PATH).to eq(Rails.root.join('crawler/data/season-board.json'))
    expect(described_class.new.path).to eq(Rails.root.join('tmp/season-board.test.json'))
  end

  it 'returns empty results when the file is missing' do
    expect(log.for('150091')).to eq(crawl: nil, extract: nil, prepare: nil)
    expect(log.busy?('150091')).to be false
    expect(log.active).to eq([])
    expect(log.last_attempt_at('150091', :crawl)).to be_nil
  end

  it 'tolerates an invalid file' do
    FileUtils.mkdir_p(File.dirname(log_path))
    File.write(log_path, '{nope')
    expect(log.for('150091')).to eq(crawl: nil, extract: nil, prepare: nil)
  end

  describe 'the queue! -> start! -> finish! lifecycle' do
    def queue_at_now
      travel_to(now) { log.queue!('150091', kind: :crawl, origin: :auto, url: 'https://x/y#/risultati/150091:a.html') }
    end

    it 'queue! records a queued entry, busy for that kind only' do
      entry = queue_at_now
      expect(entry).to have_attributes(
        fin_event_id: '150091', kind: :crawl, origin: :auto, status: :queued,
        queued_at: now, started_at: nil, finished_at: nil, url: 'https://x/y#/risultati/150091:a.html'
      )
      expect(entry).to be_queued
      travel_to(now) do
        expect(log.busy?('150091')).to be true
        expect(log.busy?('150091', kind: :extract)).to be false
      end
    end

    it 'start! keeps origin, url & queued_at of the queued entry' do
      queue_at_now
      travel_to(now + 5.minutes) do
        entry = log.start!('150091', kind: :crawl)
        expect(entry).to have_attributes(status: :running, origin: :auto, queued_at: now, started_at: now + 5.minutes,
                                         url: 'https://x/y#/risultati/150091:a.html')
        expect(log.busy?('150091', kind: :crawl)).to be true
      end
    end

    it 'finish! closes the entry' do
      queue_at_now
      travel_to(now + 5.minutes) { log.start!('150091', kind: :crawl) }
      travel_to(now + 20.minutes) do
        entry = log.finish!('150091', kind: :crawl, status: :done, message: 'ok')
        expect(entry).to have_attributes(status: :done, finished_at: now + 20.minutes, message: 'ok', started_at: now + 5.minutes)
        expect(log.busy?('150091')).to be false
        expect(log.last_attempt_at('150091', :crawl)).to eq(now + 20.minutes)
      end
    end

    it 'keeps crawl & extract entries independent' do
      log.queue!('150091', kind: :crawl, origin: :manual)
      log.start!('150091', kind: :extract, origin: :manual)
      result = log.for('150091')
      expect(result[:crawl]).to have_attributes(status: :queued, origin: :manual)
      expect(result[:extract]).to have_attributes(status: :running, origin: :manual)
    end

    it 'start! works without a previous queue! (origin defaults to manual)' do
      entry = log.start!('150092', kind: :extract)
      expect(entry).to have_attributes(status: :running, origin: :manual, queued_at: nil)
    end

    it 'a new queue! resets the previous attempt' do
      log.queue!('150091', kind: :crawl, origin: :auto)
      log.finish!('150091', kind: :crawl, status: :failed, message: 'timeout')
      entry = log.queue!('150091', kind: :crawl, origin: :manual)
      expect(entry).to have_attributes(status: :queued, origin: :manual, finished_at: nil, message: nil)
    end

    it 'accepts Integer FIN ids & String kinds/statuses' do
      log.queue!(150_091, kind: 'crawl', origin: 'auto')
      expect(log.finish!(150_091, kind: 'crawl', status: 'failed').status).to eq(:failed)
      expect(log.for('150091')[:crawl].status).to eq(:failed)
    end

    it 'rejects unknown kinds, origins & statuses' do
      expect { log.queue!('1', kind: :nope, origin: :auto) }.to raise_error(ArgumentError)
      expect { log.queue!('1', kind: :crawl, origin: :nope) }.to raise_error(ArgumentError)
      expect { log.finish!('1', kind: :crawl, status: :running) }.to raise_error(ArgumentError)
      expect { log.queue!('', kind: :crawl, origin: :auto) }.to raise_error(ArgumentError)
    end

    it 'writes atomically (no leftover tmp file) & persists across instances' do
      log.queue!('150091', kind: :crawl, origin: :auto)
      expect(File.exist?("#{log_path}.tmp")).to be false
      expect(described_class.new(path: log_path).for('150091')[:crawl]).to be_queued
    end
  end

  describe 'staleness' do
    it 'treats a running entry older than RUNNING_STALE_AFTER as not busy' do
      travel_to(now) { log.start!('150091', kind: :crawl, origin: :auto) }
      travel_to(now + described_class::RUNNING_STALE_AFTER - 1.minute) do
        expect(log.busy?('150091')).to be true
        expect(log.active.size).to eq(1)
      end
      travel_to(now + described_class::RUNNING_STALE_AFTER + 1.minute) do
        expect(log.busy?('150091')).to be false
        expect(log.for('150091')[:crawl]).to be_stale
        expect(log.active).to eq([])
      end
    end

    it 'treats a queued entry older than QUEUED_STALE_AFTER as not busy' do
      travel_to(now) { log.queue!('150091', kind: :crawl, origin: :auto) }
      travel_to(now + described_class::QUEUED_STALE_AFTER - 1.minute) { expect(log.busy?('150091')).to be true }
      travel_to(now + described_class::QUEUED_STALE_AFTER + 1.minute) { expect(log.busy?('150091')).to be false }
    end

    it 'uses thresholds compatible with the 30-minute crawl timeout' do
      expect(described_class::RUNNING_STALE_AFTER).to eq(40.minutes)
    end

    it 'keeps queued entries busy while a full daily re-check batch waits on the single background worker' do
      # (SeasonRecheckJob::MAX_CRAWLS_PER_RUN crawls of up to ~36 minutes each, run one at a time)
      worst_wait = SeasonRecheckJob::MAX_CRAWLS_PER_RUN * (MeetingCrawlJob::CRAWL_TIMEOUT + MeetingCrawlJob::IDLE_WAIT_TIMEOUT +
                                                           MeetingCrawlJob::PAUSE_AFTER_CRAWL)
      expect(described_class::QUEUED_STALE_AFTER).to eq(12.hours)
      expect(described_class::QUEUED_STALE_AFTER).to be > worst_wait
      travel_to(now) { log.queue!('150091', kind: :crawl, origin: :auto) }
      travel_to(now + 9.hours) { expect(log.busy?('150091')).to be true }
    end
  end

  describe '#active' do
    it 'lists the queued & running (non-stale) entries, running first, then by time' do
      travel_to(now) do
        log.queue!('1', kind: :crawl, origin: :auto)
        log.queue!('2', kind: :crawl, origin: :auto)
        log.queue!('3', kind: :crawl, origin: :auto)
        log.finish!('3', kind: :crawl, status: :done)
      end
      travel_to(now + 1.minute) { log.start!('2', kind: :crawl) }
      travel_to(now + 2.minutes) do
        expect(log.active.map { |e| [e.fin_event_id, e.status] }).to eq([['2', :running], ['1', :queued]])
      end
    end
  end

  describe '#last_attempt_at' do
    it 'returns the most recent timestamp of the entry' do
      travel_to(now) { log.queue!('1', kind: :extract, origin: :manual) }
      expect(log.last_attempt_at('1', :extract)).to eq(now)
      expect(log.last_attempt_at('1', :crawl)).to be_nil
    end
  end

  describe 'file reads' do
    let(:store) { FedernuotoWatch::StateStore.new(path: log_path) }

    before(:each) do
      described_class.new(path: log_path).queue!('1', kind: :crawl, origin: :auto)
      allow(FedernuotoWatch::StateStore).to receive(:new).and_return(store)
      allow(store).to receive(:read).and_call_original
    end

    it 'reads the file once for any number of lookups' do
      10.times { |i| log.for(i.to_s) }
      log.active
      log.busy?('1')
      expect(store).to have_received(:read).once
      expect(log.entry('1', :crawl)).to have_attributes(status: :queued)
    end

    it 'sees its own writes' do
      expect(log.entry('1', :crawl)).to have_attributes(status: :queued)
      log.start!('1', kind: :crawl)
      expect(log.entry('1', :crawl)).to have_attributes(status: :running)
    end

    it 'sees the writes of other instances after #reload!' do
      expect(log.entry('1', :crawl)).to have_attributes(status: :queued)
      described_class.new(path: log_path).finish!('1', kind: :crawl, status: :done)
      expect(log.entry('1', :crawl)).to have_attributes(status: :queued)
      expect(log.reload!.entry('1', :crawl)).to have_attributes(status: :done)
    end
  end

  # Phase 15: the Sources crawls & extractions (key 'src:<sha1>', label, heartbeat).
  describe 'source entries' do
    let(:key) { described_class.source_key('crawl:microplus', 'https://fin2025.microplustiming.com/x.php') }

    it 'builds a stable src: key that is never a FIN id' do
      expect(key).to match(/\Asrc:\h{40}\z/)
      expect(key).to eq(described_class.source_key('crawl:microplus', 'https://fin2025.microplustiming.com/x.php'))
      expect(key).not_to eq(described_class.source_key('crawl:ficr', 'https://fin2025.microplustiming.com/x.php'))
      expect(described_class.source_key?(key)).to be true
      expect(described_class.source_key?('150091')).to be false
    end

    it 'keeps the label through queue! -> start! -> finish!' do
      log.queue!(key, kind: :crawl, origin: :manual, url: 'u', label: 'Microplus: x.php')
      expect(log.entry(key, :crawl)).to have_attributes(label: 'Microplus: x.php', source?: true)
      log.start!(key, kind: :crawl)
      log.finish!(key, kind: :crawl, status: :done, message: 'ok')
      expect(log.entry(key, :crawl)).to have_attributes(status: :done, label: 'Microplus: x.php', message: 'ok')
    end

    it 'writes no label key for the FIN entries (old files stay the same)' do
      log.queue!('150091', kind: :crawl, origin: :auto)
      log.start!('150091', kind: :crawl)
      expect(JSON.parse(File.read(log_path)).dig('entries', '150091', 'crawl')).not_to have_key('label')
      expect(log.entry('150091', :crawl)).to have_attributes(label: nil, heartbeat_at: nil, source?: false)
    end

    it 'reads the entries written before phase 15 (no label, no heartbeat)' do
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(log_path, { 'entries' => { '1' => { 'crawl' => { 'origin' => 'auto', 'status' => 'done' } } } }.to_json)
      expect(log.entry('1', :crawl)).to have_attributes(status: :done, label: nil, heartbeat_at: nil)
    end

    it 'writes the heartbeat of a running entry only' do
      log.queue!(key, kind: :crawl, origin: :manual)
      expect(log.heartbeat!(key, kind: :crawl)).to be_nil
      log.start!(key, kind: :crawl)
      travel_to(now) { expect(log.heartbeat!(key, kind: :crawl).heartbeat_at).to eq(now) }
    end

    it 'keeps a running entry with a recent heartbeat busy past RUNNING_STALE_AFTER' do
      travel_to(now) { log.start!(key, kind: :crawl) }
      late = now + described_class::RUNNING_STALE_AFTER + 20.minutes
      travel_to(late - 1.minute) { log.heartbeat!(key, kind: :crawl) }
      travel_to(late) do
        expect(log.reload!.busy?(key, kind: :crawl)).to be true
        expect(log.active.map(&:fin_event_id)).to eq([key])
      end
      travel_to(late + described_class::HEARTBEAT_STALE_AFTER + 1.minute) { expect(log.reload!.busy?(key, kind: :crawl)).to be false }
    end
  end

  # 0.10.99: run id and reason (SeasonBoard::ActivityReconciler), compare-and-set close, one write for many keys.
  describe 'run id, reason, finish_unchanged! and record_many!' do
    it 'keeps the run id of a prepare from queue! through start! to finish!, and writes no run_id key for the others' do
      log.queue!('150091', kind: :prepare, origin: :auto, run_id: 42)
      expect(log.start!('150091', kind: :prepare).run_id).to eq(42)
      expect(log.finish!('150091', kind: :prepare, status: :done).run_id).to eq(42)
      log.queue!('150092', kind: :crawl, origin: :auto)
      expect(JSON.parse(File.read(log_path)).dig('entries', '150092', 'crawl')).not_to have_key('run_id')
    end

    it 'stores a reason on finish! (lost?), dropped by the next close without one' do
      log.queue!('150091', kind: :crawl, origin: :auto)
      expect(log.finish!('150091', kind: :crawl, status: :failed, reason: described_class::LOST_REASON)).to be_lost
      expect(log.finish!('150091', kind: :crawl, status: :failed).reason).to be_nil
    end

    it 'finish_unchanged! closes the attempt only while it is the one read' do
      queued = log.queue!('150091', kind: :crawl, origin: :auto)
      expect(log.finish_unchanged!(queued, status: :failed, message: 'lost')).to have_attributes(status: :failed, message: 'lost')
      queued = log.queue!('150091', kind: :crawl, origin: :auto)
      log.start!('150091', kind: :crawl)
      expect(log.finish_unchanged!(queued, status: :failed)).to be_nil
      expect(log.entry('150091', :crawl)).to be_running
      gone = queued.with(fin_event_id: '150099')
      expect(log.finish_unchanged!(gone, status: :failed)).to be_nil
      expect(JSON.parse(File.read(log_path))['entries']).not_to have_key('150099')
    end

    it 'record_many! writes a finished attempt for each key in one write, skipping the busy ones' do
      log.queue!('150092', kind: :crawl, origin: :auto)
      log.finish!('150093', kind: :crawl, status: :failed)
      started = now - 5.minutes
      written = travel_to(now) do
        log.record_many!(%w[150091 150092 150093 150091], kind: :crawl, status: :done, origin: :manual, message: 'Sources', started_at: started)
      end
      expect(written).to eq(%w[150091 150093])
      expect(log.entry('150091', :crawl)).to have_attributes(status: :done, origin: :manual, finished_at: now, started_at: started, message: 'Sources')
      expect(log.entry('150092', :crawl)).to be_queued
      expect(log.entry('150093', :crawl)).to be_done
      expect(log.record_many!([], kind: :crawl, status: :done, origin: :manual)).to eq([])
    end
  end
end
