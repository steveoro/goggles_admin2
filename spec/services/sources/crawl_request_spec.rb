# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sources::CrawlRequest do
  let(:data_root) { Pathname.new(Dir.mktmpdir('crawl-request-')) }
  let(:guard) { Sources::FileGuard.new(root: data_root) }
  let(:season_id) { 242 }

  def request(kind, **values) = described_class.from({ kind:, season_id: }.merge(values))

  after(:each) { FileUtils.rm_rf(data_root) }

  describe 'URL checks per kind (the Pull page base URLs, now Sources::CrawlKinds)' do
    {
      'fin_meeting' => ['https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html',
                        ['https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/',
                         'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/ (+<LINK>)',
                         'https://fin2025.microplustiming.com/x.php']],
      'microplus' => ['https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php',
                      ['https://fin2025.microplustiming.com/', 'https://fin2025.microplustiming.com/ (+<PAGE>.php)',
                       'https://microplustiming.com.evil.example/x.php', 'ftp://fin2025.microplustiming.com/x.php']],
      'ficr' => ["https://nuoto.ficr.it/#/NUO/tempi/25'%20TROFEO%20ACSI%20CITTA'%20DI%20BRESCIA/2023/29/5/AAF/3",
                 ['https://nuoto.ficr.it/', 'https://nuoto.ficr.it.evil.example/#/NUO/x']],
      'goandswim' => ['https://risultati.goandswim.it/evento/5ce2d74fd05d4a659b511251caec6132',
                      ['https://risultati.goandswim.it/', 'https://risultati.goandswim.it/evento/ (+<EVENT_ID>)', 'https://goandswim.it/evento/x']]
    }.each do |kind, (valid_url, invalid_urls)|
      it "accepts a #{kind} meeting URL and refuses placeholders and other sites" do
        expect(request(kind, url: valid_url).errors(guard:)).to be_empty
        invalid_urls.each do |url|
          expect(request(kind, url:).errors(guard:)).to eq([:"invalid_url_#{kind}"]), url
        end
        expect(request(kind, url: nil).errors(guard:)).to eq([:"invalid_url_#{kind}"])
      end
    end
  end

  it 'refuses an unknown kind or season' do
    expect(request('ftp', url: 'x').errors(guard:)).to eq([:unknown_kind])
    expect(described_class.from(kind: 'ficr', season_id: 0, url: 'https://nuoto.ficr.it/#/NUO/x').errors(guard:)).to eq([:unknown_season])
  end

  it 'checks the FIN calendar menu item and season text' do
    expect(request('calendar', sub_menu_type: 'Riepilogo Eventi', year_text: '2023/2024').errors(guard:)).to be_empty
    expect(request('calendar', sub_menu_type: 'Nope', year_text: '23/24').errors(guard:)).to eq(%i[invalid_sub_menu invalid_year_text])
  end

  describe 'a calendar CSV crawl' do
    let(:csv) { data_root.join('calendar.new', season_id.to_s, 'cal.csv') }

    before(:each) do
      FileUtils.mkdir_p(csv.dirname)
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv)
    end

    it 'accepts a CSV of calendar.new/<season> and refuses anything else' do
      expect(request('calendar_results', file_path: csv.to_s).errors(guard:)).to be_empty
      done = data_root.join('calendar.done', season_id.to_s, 'cal.csv')
      FileUtils.mkdir_p(done.dirname)
      FileUtils.cp(csv, done)
      other_season = data_root.join('calendar.new', '262', 'cal.csv')
      FileUtils.mkdir_p(other_season.dirname)
      FileUtils.cp(csv, other_season)
      [done, other_season, '/etc/passwd', 'calendar.new/242/../../../outside.csv'].each do |path|
        expect(request('calendar_results', file_path: path.to_s).errors(guard:)).to eq([:invalid_calendar_file]), path.to_s
      end
    end

    it 'times out after 30 minutes per meeting, at most 12 hours, and uses the season result layout' do
      req = request('calendar_results', file_path: csv.to_s)
      expect(req.meeting_count).to eq(10)
      expect(req.timeout).to eq(5.hours)
      allow(CrawlerCalendar::Sheet).to receive(:new).and_return(instance_double(CrawlerCalendar::Sheet, row_count: 100))
      expect(req.timeout).to eq(12.hours)
      expect(Sources::CrawlKinds.result_layout_for(172)).to eq(1)
      expect(Sources::CrawlKinds.result_layout_for(242)).to eq(2)
    end
  end

  it 'keys the activity entry by kind and target, and labels it' do
    req = request('microplus', url: 'https://fin2025.microplustiming.com/x.php')
    expect(req.key).to eq(SeasonBoard::ActivityLog.source_key('crawl:microplus', 'https://fin2025.microplustiming.com/x.php'))
    expect(req.label).to eq(I18n.t('sources.crawl.labels.microplus', detail: 'fin2025.microplustiming.com/x.php'))
    expect(req.to_job_args).to eq(kind: 'microplus', season_id:, url: 'https://fin2025.microplustiming.com/x.php')
    expect(req.timeout).to eq(30.minutes)
    expect(req.fin_server?).to be false
    expect(request('fin_meeting', url: 'x')).to be_fin_server
  end
end
