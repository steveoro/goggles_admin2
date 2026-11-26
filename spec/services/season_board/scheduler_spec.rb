# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::Scheduler do
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:fin_id) { '150091' }
  let(:url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:m.html' }

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Notifier).to receive(:ping)
    allow(SeasonBoard::Snapshot).to receive(:invalidate!)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  describe '.crawl!' do
    def crawl!(origin: :manual)
      described_class.crawl!(season_id: 262, fin_event_id: fin_id, url:, origin:)
    end

    it 'records the queued attempt, enqueues the job, pings & returns true' do
      expect { expect(crawl!(origin: :auto)).to be true }
        .to have_enqueued_job(MeetingCrawlJob).with(season_id: 262, fin_event_id: fin_id, url:, origin: 'auto').on_queue('background')
        .at_priority(described_class::AUTO_PRIORITY)
      expect(activity_log.entry(fin_id, :crawl)).to have_attributes(status: :queued, origin: :auto, url:)
      expect(SeasonBoard::Notifier).to have_received(:ping)
      expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(262)
    end

    it "queues the operator's crawl first (0.10.103): board 0, Sources 10, automatic calendar 15, automatic crawls 20" do
      crawl!(origin: :manual)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job).to include(job: MeetingCrawlJob)
      expect(job[:priority].to_i).to eq(0)
      expect(SourceCrawlJob.new.priority).to eq(10)
      expect([described_class::AUTO_CALENDAR_PRIORITY, described_class::AUTO_PRIORITY]).to eq([15, 20])
    end

    it 'gives an automatic extraction the automatic priority unless one is asked' do
      allow(described_class).to receive(:create_run).and_return(instance_double(Ops::PipelineRun, id: 7))
      expect { described_class.extract!(season_id: 262, fin_event_id: fin_id, origin: :auto, pdf_path: '/x/m.pdf') }
        .to have_enqueued_job(ManifestExtractJob).at_priority(described_class::AUTO_PRIORITY)
    end

    it 'does nothing & returns false when a crawl is already queued or running' do
      activity_log.start!(fin_id, kind: :crawl, origin: :auto, url:)
      expect { expect(crawl!).to be false }.not_to have_enqueued_job(MeetingCrawlJob)
      expect(activity_log.entry(fin_id, :crawl)).to have_attributes(status: :running, origin: :auto)
      expect(SeasonBoard::Notifier).not_to have_received(:ping)
      expect(SeasonBoard::Snapshot).not_to have_received(:invalidate!)
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

    it 'writes an extract run row for an automatic attempt and passes its id to the job (phase 10)' do
      expect { described_class.extract!(season_id: 262, fin_event_id: fin_id, origin: :auto, pdf_path: '/m/manifest-x.pdf') }
        .to have_enqueued_job(ManifestExtractJob).with(season_id: 262, fin_event_id: fin_id, engine: nil, run_id: Integer)
      expect(Ops::PipelineRun.last).to have_attributes(kind: 'extract', origin: 'auto', subject_key: 'manifest-x.pdf', status: 'queued')
      expect(activity_log.entry(fin_id, :extract)).to have_attributes(status: :queued, origin: :auto)
    end
  end

  describe '.prepare!' do
    let(:source_path) { '/tmp/results.new/262/m-lt4.json' }

    def prepare!(**options)
      described_class.prepare!(season_id: 262, source_path:, origin: :auto, fin_event_id: fin_id, **options)
    end

    it 'writes the queued prepare run, logs it, enqueues DataFixPrepareJob on the pipeline queue and pings' do
      run = nil
      expect { run = prepare!(up_to: 1, mode: 'rebuild_stale', phases: [5]) }
        .to have_enqueued_job(DataFixPrepareJob).on_queue('pipeline')
        .with(source_path:, season_id: 262, origin: 'auto', up_to: 1, mode: 'rebuild_stale', phases: [5], fin_event_id: fin_id, run_id: Integer)
      expect(run).to have_attributes(kind: 'prepare', origin: 'auto', status: 'queued', subject_key: 'm', message: 'rebuild_stale')
      expect(run.pipeline_source).to have_attributes(season_id: 262, base: 'm')
      expect(run.job_id).to be_present
      expect(activity_log.entry(fin_id, :prepare)).to have_attributes(status: :queued, origin: :auto, run_id: run.id)
      expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(262)
    end

    it 'passes the FIN id to the job (0.10.99: the job closes the board entry itself), nil for a non-FIN source' do
      expect { prepare! }.to have_enqueued_job(DataFixPrepareJob).with(hash_including(fin_event_id: fin_id))
      expect { described_class.prepare!(season_id: 262, source_path: '/tmp/results.new/262/n-lt4.json', origin: :operator) }
        .to have_enqueued_job(DataFixPrepareJob).with(hash_including(fin_event_id: nil))
    end

    it 'refuses a second request while the first run is queued' do
      prepare!
      expect { expect(prepare!).to be false }.not_to have_enqueued_job(DataFixPrepareJob)
    end

    it 'refuses while the source lease is held or a commit of it is pending' do
      Ops::PipelineSource.for_path!(source_path).acquire_lease!('operator:1:x')
      expect(prepare!).to be false
      Ops::PipelineSource.for_path!(source_path).release_lease!('operator:1:x')
      FactoryBot.create(:ops_commit_report, source_base: 'm', status: 'queued')
      expect(prepare!).to be false
    end

    it 'is refused without the ops DB' do
      allow(Ops).to receive(:available?).and_return(false)
      expect { expect(prepare!).to be false }.not_to have_enqueued_job(DataFixPrepareJob)
    end

    it 'logs an operator request as manual' do
      described_class.prepare!(season_id: 262, source_path:, origin: :operator, fin_event_id: fin_id)
      expect(activity_log.entry(fin_id, :prepare).origin).to eq(:manual)
      expect(Ops::PipelineRun.last.origin).to eq('operator')
    end

    it 'closes the run as failed and re-raises when the enqueue fails' do
      allow(DataFixPrepareJob).to receive(:perform_later).and_raise(ActiveRecord::ConnectionNotEstablished, 'no queue db')
      expect { prepare! }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(Ops::PipelineRun.last).to have_attributes(status: 'failed', error: 'enqueue failed: no queue db')
      expect(activity_log.entry(fin_id, :prepare)).to have_attributes(status: :failed)
    end
  end

  describe '.calendar_crawl! (0.10.103)' do
    let(:season) { GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin) || GogglesDb::Season.last }
    let(:request) { Sources::CrawlRequest.eventi_calendar(season) }

    it "queues the crawler tab's default 'Eventi' calendar crawl, automatic, after the operator's crawls and before the automatic ones" do
      expect { expect(described_class.calendar_crawl!(season:, origin: :auto)).to be true }
        .to have_enqueued_job(SourceCrawlJob).with(kind: 'calendar', season_id: season.id, sub_menu_type: 'Eventi',
                                                   year_text: Sources::CrawlKinds.year_text_for(season), key: request.key,
                                                   label: request.label, origin: 'auto').on_queue('background').at_priority(described_class::AUTO_CALENDAR_PRIORITY)
      expect(activity_log.entry(request.key, :crawl)).to have_attributes(status: :queued, origin: :auto, url: request.target, label: request.label)
      expect(SeasonBoard::Notifier).to have_received(:ping)
    end

    it 'shares the key of the manual crawl of the crawler tab: never twice' do
      activity_log.queue!(request.key, kind: :crawl, origin: :manual, url: request.target)
      expect { expect(described_class.calendar_crawl!(season:, origin: :auto)).to be false }.not_to have_enqueued_job(SourceCrawlJob)
    end

    it 'queues a manual request at the default priority, as an operator run' do
      expect { described_class.calendar_crawl!(season:, origin: :manual) }
        .to have_enqueued_job(SourceCrawlJob).with(hash_including(origin: 'operator')).at_priority(10)
    end

    it 'refuses a season unknown to the local DB' do
      unknown = FactoryBot.build_stubbed(:season, id: 999_999)
      expect { expect(described_class.calendar_crawl!(season: unknown, origin: :auto)).to be false }.not_to have_enqueued_job(SourceCrawlJob)
    end

    it 'closes the entry as failed and re-raises when the enqueue fails' do
      allow(SourceCrawlJob).to receive(:set).and_raise(ActiveRecord::ConnectionNotEstablished, 'no queue db')
      expect { described_class.calendar_crawl!(season:, origin: :auto) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(activity_log.entry(request.key, :crawl)).to have_attributes(status: :failed)
    end
  end
end
