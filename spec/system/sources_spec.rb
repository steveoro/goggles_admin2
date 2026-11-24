# frozen_string_literal: true

require 'rails_helper'

# Phase 15 journeys of the Sources area. Everything lives in a temporary 'crawler/data' root
# (SeasonBoard::DiskIndex.default_data_dir, hence Sources.data_root, is stubbed to it); the crawler is a fake
# (SourceCrawlJob.crawler_client_factory), the PDF parser and the Data-Fix builds are stubbed. The jobs queued by
# the clicks are performed by the example itself, as the Solid Queue workers would.
RSpec.describe 'Sources area' do
  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir('system-sources-')).realpath.join('crawler', 'data') }
  let(:season) { SeasonBoard::Builder.latest_season }
  let(:season_dir) { data_root.join('results.new', season.id.to_s) }

  # Performs the queued jobs of +job_class+ (the arguments the click enqueued).
  def perform_queued(job_class)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job['job_class'] == job_class.name }
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    jobs.each { |job| job_class.perform_now(**ActiveJob::Arguments.deserialize(job['arguments']).first.symbolize_keys) }
    jobs.size
  end

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_root)
    allow(Outbox).to receive(:data_root).and_return(data_root)
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    sign_in_through_form(admin_user)
  end

  after(:each) do
    FileUtils.rm_rf(data_root.dirname.dirname)
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
    SourceCrawlJob.crawler_client_factory = -> { CrawlerClient.new }
    SourceCrawlJob.launcher_factory = -> { CrawlerLauncher.new }
    SourceCrawlJob.sleeper = ->(seconds) { sleep(seconds) }
  end

  describe 'a Microplus meeting: crawl, Prepare, then the inbox' do
    let(:microplus_url) { 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php' }
    let(:source_name) { '2025-06-24-Trofeo_Microplus-lt4.json' }
    let(:fixture) { JSON.parse(Rails.root.join('spec/fixtures/data_fix/pipeline/new_meeting.json').read) }
    # Scriptable stand-in for the Node crawler: the Microplus command "writes" a non-FIN LT4 source.
    let(:fake_crawler) do
      dir = season_dir
      name = source_name
      Class.new do
        define_method(:initialize) { @statuses = [{ 'timestamp' => 1.hour.ago.utc.strftime('%Y%m%d-%H%M%S'), 'status' => 'OK, idle' }] }
        define_method(:status) { @statuses.size > 1 ? @statuses.shift : @statuses.first }
        define_method(:pull_microplus) do |**_args|
          File.write(dir.join(name), JSON.pretty_generate('layoutType' => 4, 'meetingName' => 'Trofeo Microplus', 'dates' => '2025-06-24',
                                                          'events' => [{ 'eventCode' => '50SL', 'relay' => false, 'results' => [] }]))
          @statuses = [@statuses.first, { 'timestamp' => Time.current.utc.strftime('%Y%m%d-%H%M%S'), 'status' => 'OK, done, idle' }]
          CrawlerClient::Result.new(ok: true, code: 200, body: {}, error: nil)
        end
      end.new
    end

    before(:each) do
      crawler = fake_crawler
      SourceCrawlJob.crawler_client_factory = -> { crawler }
      SourceCrawlJob.launcher_factory = -> { instance_double(CrawlerLauncher, ensure_running!: :already_running) }
      SourceCrawlJob.sleeper = ->(_seconds) {}
      # (the prepare: the phase 1-3 data of the 'new_meeting' fixture, minimal phases 4-5, clean verdicts 4-5)
      data = fixture
      allow(DataFix::Pipeline::Recipes).to receive(:build) do |pipe, phase|
        case phase
        when 1..3 then PhaseFileManager.new(pipe.phase_path(phase)).write!(data: data["phase#{phase}"], meta: {})
        when 4 then PhaseFileManager.new(pipe.phase_path(4)).write!(data: { 'sessions' => [] }, meta: {})
        else PhaseFileManager.new(pipe.phase_path(5)).write_payload!('name' => 'phase5', 'programs' => [])
        end
        {}
      end
      [4, 5].each do |phase|
        allow("DataFix::Verdicts::Phase#{phase}".constantize).to receive(:new) do
          instance_double("DataFix::Verdicts::Phase#{phase}", call: DataFix::Verdict.build(phase:, status: 'clean'))
        end
      end
      stub_valid_structure
      allow(DataFix::Guards).to receive(:check).and_return(DataFix::Guards::Result.new(level: :ok, reasons: [], verdict: nil, acknowledged: false))
      allow(DataFix::Pipeline).to receive(:for).and_wrap_original do |original, *args, **options|
        original.call(*args, **options).tap { |pipe| pipe.relay_enrichment_count = 0 }
      end
    end

    it 'queues the crawl, lists the new source as non-FIN, prepares it and shows it in Needs you' do
      visit(sources_crawler_path(season_id: season.id))
      fill_in('sources-crawl-microplus-url', with: microplus_url)
      accept_confirm { click_button('btn-sources-crawl-microplus') }
      expect(page).to have_css('.toast', text: I18n.t('sources.crawl.labels.microplus', detail: microplus_url.delete_prefix('https://')))
      expect(perform_queued(SourceCrawlJob)).to eq(1)

      visit(sources_crawler_path(season_id: season.id))
      expect(page).to have_css('#sources-crawler-recent', text: source_name)

      visit(sources_results_path(season_id: season.id))
      row = find("#sources-results-table tr[data-sources-file='#{source_name}']")
      expect(row).to have_css('.badge', text: I18n.t('sources.results.badges.non_fin'))
      accept_confirm { row.click_button(I18n.t('sources.results.actions.prepare')) }
      expect(page).to have_css('.toast', text: I18n.t('sources.results.prepare.queued', name: source_name))
      expect(perform_queued(DataFixPrepareJob)).to eq(1)

      visit(sources_results_path(season_id: season.id))
      expect(find("#sources-results-table tr[data-sources-file='#{source_name}']")).to have_css('.badge.text-bg-warning')

      visit(root_path)
      within('#dashboard-needs-you') do
        expect(page).to have_css("li.inbox-item[data-inbox-key^='unmatched:2025-06-24-Trofeo_Microplus:']",
                                 text: '2025-06-24-Trofeo_Microplus')
      end
      expect_no_js_errors
    end
  end

  describe 'the file editor' do
    let!(:json_path) { season_dir.join('meeting.json').tap { |path| File.write(path, %({"name": "Trofeo"})) } }

    it 'opens a JSON in CodeMirror, stops an invalid text and saves a valid one' do
      visit(sources_files_path(dir: "results.new/#{season.id}"))
      find("tr[data-sources-file='meeting.json'] a[title='#{I18n.t('sources.files.actions.edit')}']").click
      expect(page).to have_css('#sources-file-edit .cm-editor')
      editor = find('#sources-file-edit .cm-content')
      editor.click
      editor.send_keys([:control, 'a'], :backspace, '{"name": ')
      # (an invalid JSON is stopped before the confirmation)
      click_button('btn-sources-file-save')
      expect(page).to have_css('[data-sources-editor-target="error"]', text: I18n.t('sources.files.edit.invalid_json_client'))
      expect(File.read(json_path)).to eq(%({"name": "Trofeo"}))

      editor.send_keys('"Trofeo 2"}')
      accept_confirm { click_button('btn-sources-file-save') }
      expect(page).to have_css('.toast', text: I18n.t('sources.files.saved', name: 'meeting.json'))
      expect(page).to have_css("tr.sources-file-focus[data-sources-file='meeting.json']")
      expect(JSON.parse(File.read(json_path))).to eq('name' => 'Trofeo 2')
      expect_no_js_errors
    end
  end

  describe 'a PDF scan, then Data-Fix (formerly the PDF page journey)' do
    let(:fixture_hash) { JSON.parse(Rails.root.join('spec/fixtures/import/pdf-teamrank-lt2.json').read) }
    let(:pdf_season) { GogglesDb::Season.find(fixture_hash['season_id']) }
    let(:pdf_path) { data_root.join('pdfs', pdf_season.id.to_s, 'pdf-teamrank.pdf') }

    before(:each) do
      FileUtils.mkdir_p(pdf_path.dirname)
      File.write(pdf_path, '%PDF')
      File.write(pdf_path.sub_ext('.txt'), "7° Trofeo Roma Nuoto Master\n(stubbed text page)\n")
      File.write(pdf_path.sub_ext('.log'), "(stubbed scan log)\n")
      parser = instance_double(
        PdfResults::FormatParser,
        scan: nil, pages: ['page 1'], page_index: 1, result_format_type: '3-finlazio', root_dao: nil, season: pdf_season,
        checked_formats: { '3-finlazio' => { valid: true, last_check: 1, valid_at: [[0]] } }, last_valid_scan_per_format: {}
      )
      allow(PdfResults::FormatParser).to receive(:new).and_return(parser)
      allow(PdfResults::L2Converter).to receive(:new).and_return(instance_double(PdfResults::L2Converter, to_hash: fixture_hash.deep_dup))
    end

    it 'queues the scan, shows the parsed result with its log, and opens Data-Fix step 1 and 2' do # rubocop:disable RSpec/MultipleExpectations
      visit(sources_pdfs_path(season_id: pdf_season.id))
      find("#sources-pdfs-table tr[data-sources-file='pdf-teamrank.pdf'] a.btn").click
      expect(page).to have_css('.sources-txt-preview', text: '7° Trofeo Roma Nuoto Master')
      click_button('btn-sources-pdf-scan')
      expect(page).to have_css('#sources-pdf-scan-status', text: I18n.t('sources.pdfs.scan.states.queued'))
      expect(perform_queued(PdfScanJob)).to eq(1)
      expect(File).to exist(data_root.join('results.new', pdf_season.id.to_s, 'pdf-teamrank.json'))

      # (the result frame reloads by itself while the scan is pending: every 5 seconds)
      summary = I18n.t('sources.pdfs.scan.full_parse', family: '3-finlazio', count: 1)
      expect(page).to have_css('#sources-pdf-scan-summary', text: summary, wait: 12)

      # (a finished result is rendered once, without a reloading frame: the log opens and stays open)
      visit(sources_pdf_path(path: "pdfs/#{pdf_season.id}/pdf-teamrank.pdf"))
      expect(page).to have_css('#sources-pdf-scan-summary', text: summary)
      expect(page).to have_no_css('turbo-frame#sources-pdf-scan[src]')
      expect(page).to have_no_text('(stubbed scan log)')
      click_button('btn-sources-pdf-scan-log')
      expect(page).to have_text('(stubbed scan log)')
      click_link('btn-sources-pdf-data-fix')

      expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 1')
      expect(page).to have_current_path(/phase_v2=1/)
      click_link('Step 2 • Teams')
      rankings_count = fixture_hash['sections'].find { |section| section['ranking'] }['rows'].size
      expect(page).to have_css('#phase2-team-scores-card', text: "#{I18n.t('data_import.data_fix.team_scores.title')} (#{rankings_count})")
      expect_no_js_errors
    end
  end
end
