# frozen_string_literal: true

require 'rails_helper'

# Crawler tab (ported from the former Pull page specs: the page, the FIN watcher preset, the "Start crawler" button).
RSpec.describe 'Sources crawler tab' do
  include_context 'with a Sources data root'

  def html = response.parsed_body

  before(:each) do
    allow(CrawlerClient).to receive(:new).and_raise('no crawler HTTP call in a page request')
    allow(RestClient::Request).to receive(:execute).and_raise('no HTTP call in a page request')
  end

  it 'renders one form per crawl kind (with real URL fields), the server state and the activity frame' do
    get(sources_crawler_path(season_id: 242))
    expect(response).to have_http_status(:success)
    Sources::CrawlKinds::URL_KINDS.each do |kind|
      form = html.at_css("form#frm-sources-crawl-#{kind.dasherize}")
      expect(form['action']).to eq(sources_crawls_path)
      expect(form.at_css('input[name="url"][type="url"]')['placeholder']).to eq(Sources::CrawlKinds::EXAMPLES[kind])
    end
    expect(html.at_css('form#frm-sources-crawl-microplus input[name="target_event"]')).to be_present
    expect(html.at_css('form#frm-sources-crawl-calendar select[name="sub_menu_type"]')).to be_present
    expect(response.body).not_to include('(+<LINK>)')
    expect(html.css("#sources-crawler-status, turbo-frame#sources-crawler-activity[src='#{sources_crawler_activity_path}'], #btn-sources-start-crawler").size)
      .to eq(3)
  end

  it 'presets the FIN calendar menu item (the watcher "Pull calendar" link)' do
    get(sources_crawler_path(sub_menu_type: 'Riepilogo Eventi'))
    expect(response.body).to include('<option selected="selected" value="Riepilogo Eventi">')
  end

  it 'lists the calendar CSVs of the season for a whole-file crawl' do
    write_data('calendar.new/242/cal.csv', 'startURL,date\n')
    get(sources_crawler_path(season_id: 242))
    expect(html.css('#sources-crawl-calendar-file option').map(&:text)).to eq(['cal.csv'])
  end

  it 'shows the queued and running crawls and the latest manual crawls in the activity frame' do
    log = SeasonBoard::ActivityLog.new
    key = SeasonBoard::ActivityLog.source_key('crawl:ficr', 'u')
    log.queue!(key, kind: :crawl, origin: :manual, label: 'FICR nuoto.ficr.it/x')
    log.queue!('150091', kind: :crawl, origin: :auto)
    log.start!('150091', kind: :crawl)
    get(sources_crawler_activity_path)
    expect(response).to have_http_status(:success)
    expect(html.at_css('turbo-frame#sources-crawler-activity')).to be_present
    expect(html.at_css('#sources-crawler-recent').text).to include('FICR nuoto.ficr.it/x')
    expect(html.at_css('[data-live-busy="true"]')).to be_present
    expect(html.at_css('#season-board-activity').text).to include(I18n.t('season_board.strip.queued', count: 1))
  end

  it 'starts the crawler server when needed (POST /sources/crawler/start)' do
    launcher = instance_double(CrawlerLauncher, ensure_running!: :already_running)
    allow(CrawlerLauncher).to receive(:new).and_return(launcher)
    post(sources_crawler_start_path)
    expect(launcher).to have_received(:ensure_running!)
    expect(response).to redirect_to(sources_crawler_path(season_id: SeasonDefaults.default_season_id))
    expect(flash[:notice]).to eq(I18n.t('federnuoto_watch.crawler.already_running'))
  end
end
