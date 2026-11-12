# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::ActivityLog do
  include ActiveSupport::Testing::TimeHelpers

  subject(:log) { described_class.new(path: log_path) }

  let(:tmp_dir) { Dir.mktmpdir('season-board-log') }
  let(:log_path) { File.join(tmp_dir, 'nested', 'season-board.json') }
  let(:now) { Time.zone.parse('2026-11-12 10:00:00') }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it 'defaults to crawler/data/season-board.json' do
    expect(described_class.new.path).to eq(Rails.root.join('crawler/data/season-board.json'))
  end

  it 'returns empty results when the file is missing' do
    expect(log.for('150091')).to eq(crawl: nil, extract: nil)
    expect(log.busy?('150091')).to be false
    expect(log.active).to eq([])
    expect(log.last_attempt_at('150091', :crawl)).to be_nil
  end

  it 'tolerates an invalid file' do
    FileUtils.mkdir_p(File.dirname(log_path))
    File.write(log_path, '{nope')
    expect(log.for('150091')).to eq(crawl: nil, extract: nil)
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
      expect(described_class::QUEUED_STALE_AFTER).to eq(2.hours)
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
end
