# frozen_string_literal: true

require 'rails_helper'

# POST /sources/crawls: queues a SourceCrawlJob, never calling the crawler in the request (ported from the former
# Pull page specs: one case per crawl kind, the placeholder refusal, the meeting selection subset).
RSpec.describe 'Sources crawls' do
  include ActiveJob::TestHelper

  include_context 'with a Sources data root'

  let(:fin_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html' }
  let(:ficr_url) { "https://nuoto.ficr.it/#/NUO/tempi/25'%20TROFEO%20ACSI%20CITTA'%20DI%20BRESCIA/2023/29/5/AAF/3" }

  before(:each) do
    allow(CrawlerClient).to receive(:new).and_raise('no crawler call in a request')
    allow(RestClient::Request).to receive(:execute).and_raise('no HTTP call in a request')
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  def crawl(**params) = post(sources_crawls_path, params: { season_id: 242 }.merge(params))

  def enqueued_args
    enqueued_jobs.select { |job| job['job_class'] == 'SourceCrawlJob' }.map { |job| ActiveJob::Arguments.deserialize(job['arguments']).first.symbolize_keys }
  end

  {
    'fin_meeting' => { url: 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html' },
    'microplus' => { url: 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php', target_event: '200 Misti' },
    'ficr' => { url: "https://nuoto.ficr.it/#/NUO/tempi/25'%20TROFEO%20ACSI%20CITTA'%20DI%20BRESCIA/2023/29/5/AAF/3" },
    'goandswim' => { url: 'https://risultati.goandswim.it/evento/5ce2d74fd05d4a659b511251caec6132' }
  }.each do |kind, params|
    it "queues a #{kind} crawl (SourceCrawlJob, logged as queued) without calling the crawler" do
      expect { crawl(kind:, **params) }.to have_enqueued_job(SourceCrawlJob).on_queue('background').with(hash_including(kind:, season_id: 242, **params))
      args = enqueued_args.first
      expect(args[:key]).to start_with('src:')
      entry = SeasonBoard::ActivityLog.new.entry(args[:key], :crawl)
      expect(entry).to have_attributes(status: :queued, origin: :manual, label: args[:label])
      expect(response).to redirect_to(sources_crawler_path(season_id: 242))
      expect(flash[:notice]).to eq(I18n.t('sources.crawl.queued', label: args[:label], count: 0))
      expect(CrawlerClient).not_to have_received(:new)
    end
  end

  it 'queues a FIN calendar crawl, the season text defaulting to the years of the season' do
    season = GogglesDb::Season.find(242)
    crawl(kind: 'calendar', sub_menu_type: 'Riepilogo Eventi', year_text: '')
    expect(enqueued_args.first).to include(kind: 'calendar', sub_menu_type: 'Riepilogo Eventi', year_text: Sources::CrawlKinds.year_text_for(season))
  end

  it 'refuses the invalid URL of each kind (and a placeholder) with the kind message' do
    { 'fin_meeting' => "#{Sources::CrawlKinds::FIN_RESULTS_BASE_URL} (+<LINK>)", 'microplus' => 'https://example.com/x.php',
      'ficr' => 'https://nuoto.ficr.it/', 'goandswim' => fin_url }.each do |kind, url|
      expect { crawl(kind:, url:) }.not_to have_enqueued_job(SourceCrawlJob)
      expect(flash[:warning]).to eq(I18n.t("sources.crawl.errors.invalid_url_#{kind}")), kind
    end
    expect { crawl(kind: 'ftp', url: 'x') }.not_to have_enqueued_job(SourceCrawlJob)
    expect(flash[:warning]).to eq(I18n.t('sources.crawl.errors.unknown_kind'))
  end

  it 'refuses a second request for the same crawl while it is queued, and tells how many crawls are ahead' do
    crawl(kind: 'ficr', url: ficr_url)
    expect { crawl(kind: 'ficr', url: ficr_url) }.not_to have_enqueued_job(SourceCrawlJob)
    expect(flash[:warning]).to include(I18n.t('sources.crawl.already_queued', label: enqueued_args.first[:label]))
    crawl(kind: 'fin_meeting', url: fin_url)
    expect(flash[:notice]).to eq(I18n.t('sources.crawl.queued_behind', label: enqueued_args.last[:label], count: 1))
  end

  describe 'a calendar CSV crawl' do
    let(:csv_path) { data_root.join('calendar.new', '9999', 'test-cal.csv') }

    before(:each) do
      FileUtils.mkdir_p(csv_path.dirname)
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv_path)
      allow(GogglesDb::Season).to receive(:exists?).and_call_original
      allow(GogglesDb::Season).to receive(:exists?).with(id: 9999).and_return(true)
    end

    it 'queues the whole file' do
      crawl(kind: 'calendar_results', season_id: 9999, file_path: 'calendar.new/9999/test-cal.csv')
      expect(enqueued_args.first).to include(kind: 'calendar_results', season_id: 9999, file_path: csv_path.to_s)
    end

    it 'writes a -sel- subset CSV of the selected rows and queues that one' do
      crawl(kind: 'calendar_results', season_id: 9999, file_path: 'calendar.new/9999/test-cal.csv', rows_count: 10, selected_rows: %w[0 4])
      subset_file = Dir.glob(csv_path.dirname.join('test-cal-sel-*.csv').to_s).first
      expect(subset_file).to be_present
      subset_rows = CSV.read(subset_file, headers: true)
      expect(subset_rows['name']).to eq(['Distanze Speciali Campania', '7° Trofeo Gonzaga - Memorial Rascaroli'])
      expect(enqueued_args.first).to include(kind: 'calendar_results', season_id: 9999, file_path: subset_file)
      expect(File).to exist(csv_path) # (the original calendar is kept)
    end

    it 'rejects an empty selection and a stale rows_count (file changed under the page)' do
      expect do
        crawl(kind: 'calendar_results', season_id: 9999, file_path: 'calendar.new/9999/test-cal.csv', rows_count: 10)
      end.not_to have_enqueued_job(SourceCrawlJob)
      expect(response).to redirect_to(sources_calendar_meetings_path(path: 'calendar.new/9999/test-cal.csv'))
      expect(flash[:warning]).to eq(I18n.t('data_import.selection.errors.no_selection'))

      crawl(kind: 'calendar_results', season_id: 9999, file_path: 'calendar.new/9999/test-cal.csv', rows_count: 5, selected_rows: %w[0])
      expect(flash[:warning]).to eq(I18n.t('data_import.selection.errors.file_changed'))
      expect(Dir.glob(csv_path.dirname.join('*-sel-*.csv').to_s)).to be_empty
    end

    it 'rejects a file outside the data root or outside calendar.new/<season>' do
      outside = sources_base_dir.join('anything.csv')
      FileUtils.cp(csv_path, outside)
      expect { crawl(kind: 'calendar_results', season_id: 9999, file_path: outside.to_s) }.not_to have_enqueued_job(SourceCrawlJob)
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
      done = write_data('calendar.done/9999/x.csv', File.read(csv_path))
      expect { crawl(kind: 'calendar_results', season_id: 9999, file_path: done.to_s) }.not_to have_enqueued_job(SourceCrawlJob)
      expect(flash[:warning]).to eq(I18n.t('sources.crawl.errors.invalid_calendar_file'))
    end
  end
end
