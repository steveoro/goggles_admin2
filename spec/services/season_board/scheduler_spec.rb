# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::Scheduler do
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:fin_id) { '150091' }
  let(:url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:m.html' }

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  describe '.crawl!' do
    def crawl!(origin: :manual)
      described_class.crawl!(season_id: 262, fin_event_id: fin_id, url:, origin:)
    end

    it 'records the queued attempt, enqueues the job, pings & returns true' do
      expect { expect(crawl!(origin: :auto)).to be true }
        .to have_enqueued_job(MeetingCrawlJob).with(season_id: 262, fin_event_id: fin_id, url:).on_queue('background')
      expect(activity_log.entry(fin_id, :crawl)).to have_attributes(status: :queued, origin: :auto, url:)
      expect(SeasonBoard::Notifier).to have_received(:ping)
    end

    it 'does nothing & returns false when a crawl is already queued or running' do
      activity_log.start!(fin_id, kind: :crawl, origin: :auto, url:)
      expect { expect(crawl!).to be false }.not_to have_enqueued_job(MeetingCrawlJob)
      expect(activity_log.entry(fin_id, :crawl)).to have_attributes(status: :running, origin: :auto)
      expect(SeasonBoard::Notifier).not_to have_received(:ping)
    end

    it 'is not blocked by a running extraction' do
      activity_log.start!(fin_id, kind: :extract)
      expect(crawl!).to be true
    end

    it 'closes the entry as failed & re-raises when the enqueue fails' do
      allow(MeetingCrawlJob).to receive(:perform_later).and_raise(ActiveRecord::ConnectionNotEstablished, 'no queue db')
      expect { crawl! }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(activity_log.entry(fin_id, :crawl)).to have_attributes(status: :failed, message: 'enqueue failed: no queue db')
    end
  end

  describe '.extract!' do
    it 'records the queued extraction & enqueues the job with the engine' do
      expect { expect(described_class.extract!(season_id: 262, fin_event_id: fin_id, engine: 'ollama')).to be true }
        .to have_enqueued_job(ManifestExtractJob).with(season_id: 262, fin_event_id: fin_id, engine: 'ollama').on_queue('background')
      expect(activity_log.entry(fin_id, :extract)).to have_attributes(status: :queued, origin: :manual)
    end

    it 'does nothing & returns false while an extraction is busy' do
      activity_log.queue!(fin_id, kind: :extract, origin: :manual)
      expect { expect(described_class.extract!(season_id: 262, fin_event_id: fin_id)).to be false }
        .not_to have_enqueued_job(ManifestExtractJob)
    end
  end
end
