# frozen_string_literal: true

require 'rails_helper'
require 'csv'
require_relative 'disk_fixtures'

RSpec.describe SeasonBoard::CalendarIndex do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('season-board-calendar-index') }
  let(:csv_name) { '20261125-262-2-FIN-calendar.csv' }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
  # (the last watcher check)
  let(:as_of) { Date.new(2026, 11, 26) }
  # Three meetings linked on both pages (the self-check needs at least MIN_COMPARABLE of them).
  let(:linked_csv) do
    [csv_row('2026-10-04', 'Uno (AA)', '150001'), csv_row('2026-10-11', 'Due (BB)', '150002'), csv_row('2026-10-18', 'Tre (CC)', '150003')]
  end
  let(:linked_rows) { [watcher_row('04/10', 'Uno', '150001'), watcher_row('11/10', 'Due', '150002'), watcher_row('18/10', 'Tre', '150003')] }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def csv_row(date, place, fin_id, cancelled: false, name: 'Meeting')
    { 'startURL' => described_class::EVENTI_START_URL, 'date' => date, 'isCancelled' => cancelled.to_s, 'name' => name, 'place' => place,
      'meetingUrl' => fin_id ? results_url(fin_id) : '', 'year' => '2026' }
  end

  def watcher_row(date, place, fin_id = nil, year: '2026', name: 'Riepilogo name')
    { 'year' => year, 'date' => date, 'name' => name, 'place' => place, 'url' => fin_id ? results_url(fin_id) : '', 'info' => '',
      'key' => "#{year} | #{date} | #{name} | #{place}" }
  end

  def csv_text(rows)
    CSV.generate(row_sep: "\r\n") do |csv|
      csv << %w[startURL date isCancelled name place meetingUrl year]
      rows.each do |row|
        csv << [row['startURL'], row['date'], row['isCancelled'], row['name'], row['place'], row['meetingUrl'], row['year']]
      end
    end
  end

  def write_calendar(rows, name: csv_name, folder: 'calendar.new')
    write_file(folder, name, csv_text(rows))
  end

  def index = described_class.new(season:, data_dir:, as_of:)

  # Link adopted by the last watcher row of +rows+ (with the linked meetings in front), or nil.
  def adopted(csv_rows, watcher_rows)
    write_calendar(linked_csv + csv_rows)
    rows = linked_rows + watcher_rows
    index.link_for(rows.last, rows)
  end

  describe 'matching key' do
    it 'adopts the link of a single-day meeting' do
      link = adopted([csv_row('2026-11-22', 'Cagliari (CA)', '150112', name: '9° Sardinia in Water')], [watcher_row('22/11', 'Cagliari')])
      expect(link).to have_attributes(url: results_url('150112'), fin_event_id: '150112', name: '9° Sardinia in Water',
                                      calendar_date: Date.new(2026, 11, 25), file_name: csv_name)
    end

    it 'matches multi-day meetings on their first & last dates' do
      expect(adopted([csv_row('2026-12-06; 2026-12-08', 'Napoli (NA)', '150115')], [watcher_row('06-08/12', 'Napoli')]))
        .to have_attributes(fin_event_id: '150115')
      expect(adopted([csv_row('2026-12-06; 2026-12-08', 'Napoli (NA)', '150115')], [watcher_row('06/12', 'Napoli')])).to be_nil
    end

    it "reads a range text across two months ('31/10-8_11')" do
      expect(adopted([csv_row('2026-10-31; 2026-11-08', 'Anzio (RM)', '150170')], [watcher_row('31/10-8_11', 'Anzio (RM)')]))
        .to have_attributes(fin_event_id: '150170')
    end

    it 'rolls the year over from December to January' do
      expect(adopted([csv_row('2026-12-30; 2027-01-02', 'Roma (RM)', '150200')], [watcher_row('30/12-02/01', 'Roma')]))
        .to have_attributes(fin_event_id: '150200')
      expect(adopted([csv_row('2026-12-31; 2027-01-02', 'Roma (RM)', '150201')], [watcher_row('31-02/01', 'Roma', year: '2027')]))
        .to have_attributes(fin_event_id: '150201')
    end

    it 'reads a CSV date written as a FIN day text with the CSV year' do
      expect(adopted([csv_row('21-22/11', 'Lodi (LO)', '150102')], [watcher_row('21-22/11', 'Lodi')])).to have_attributes(fin_event_id: '150102')
    end

    it 'normalizes the places (province suffix, accents, punctuation, case, spaces, several places)' do
      expect(described_class.normalize_places('Città di Castello (PG)')).to eq(['citta di castello'])
      expect(described_class.normalize_places('Citta`  di  CASTELLO')).to eq(['citta di castello'])
      expect(described_class.normalize_places('Ostia - RM')).to eq(['ostia'])
      expect(described_class.normalize_places('San Marino (RSM)')).to eq(['san marino'])
      expect(described_class.normalize_places("L'Aquila (AQ)")).to eq(['l aquila'])
      expect(described_class.normalize_places('Viterbo (VT); Roma (RM)')).to eq(%w[roma viterbo])
      expect(described_class.normalize_places('-')).to eq([])
    end

    it 'matches the places through the normalization' do
      expect(adopted([csv_row('2026-11-08', "L'Aquila (AQ)", '150094')], [watcher_row('08/11', 'l’Aquila')])).to have_attributes(fin_event_id: '150094')
      expect(adopted([csv_row('2026-11-08', 'Città di Castello (PG)', '150094')], [watcher_row('08/11', 'Citta` di Castello')]))
        .to have_attributes(fin_event_id: '150094')
    end

    it 'never compares the names' do
      expect(adopted([csv_row('2026-11-22', 'Noci (BA)', '150645', name: 'Campionato Indoor')],
                     [watcher_row('22/11', 'Noci (BA)', name: 'Something else entirely')])).to have_attributes(fin_event_id: '150645')
    end

    it 'never matches a row without a place or with an unreadable date' do
      expect(adopted([csv_row('2027-02-06; 2027-02-21', '', '150278')], [watcher_row('06-21/02', '-', year: '2027')])).to be_nil
      expect(adopted([csv_row('soon', 'Roma (RM)', '150278')], [watcher_row('soon', 'Roma')])).to be_nil
    end
  end

  describe 'adoption rules' do
    it 'adopts nothing for a key shared by two CSV rows' do
      csv = [csv_row('2026-11-22', 'Napoli (NA)', '150105'), csv_row('2026-11-22', 'Napoli (NA)', '150106')]
      expect(adopted(csv, [watcher_row('22/11', 'Napoli')])).to be_nil
    end

    it 'adopts nothing for a key shared by two watcher rows' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows + [watcher_row('22/11', 'Napoli', name: 'A'), watcher_row('22/11', 'Napoli (NA)', name: 'B')]
      expect(rows.filter_map { |row| index.link_for(row, rows) }).to be_empty
    end

    it 'adopts nothing from a cancelled CSV row' do
      expect(adopted([csv_row('2026-11-22', 'Napoli (NA)', '150105', cancelled: true)], [watcher_row('22/11', 'Napoli')])).to be_nil
    end

    it 'adopts nothing from a CSV row without FIN id' do
      expect(adopted([csv_row('2026-11-22', 'Napoli (NA)', nil)], [watcher_row('22/11', 'Napoli')])).to be_nil
    end

    it 'adopts nothing when the FIN id is already on another watcher row' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows + [watcher_row('29/11', 'Matera', '150105'), watcher_row('22/11', 'Napoli')]
      expect(index.link_for(rows.last, rows)).to be_nil
    end

    it 'adopts nothing when two rows would adopt the same FIN id' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105'), csv_row('2026-11-29', 'Bari (BA)', '150105')])
      rows = linked_rows + [watcher_row('22/11', 'Napoli'), watcher_row('29/11', 'Bari')]
      expect(rows.filter_map { |row| index.link_for(row, rows) }).to be_empty
    end

    it 'never lends a link to a watcher row with its own URL' do
      write_calendar(linked_csv)
      expect(index.link_for(linked_rows.first, linked_rows)).to be_nil
    end

    it 'adopts nothing when a watcher row with its own link shares the key of the link-less one' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows + [watcher_row('22/11', 'Napoli', '150120', name: 'A'), watcher_row('22/11', 'Napoli', name: 'B')]
      expect(rows.filter_map { |row| index.link_for(row, rows) }).to be_empty
    end

    it 'adopts nothing when a cancelled CSV twin shares the key' do
      csv = [csv_row('2026-11-22', 'Napoli (NA)', '150105'), csv_row('2026-11-22', 'Napoli (NA)', '150106', cancelled: true)]
      expect(adopted(csv, [watcher_row('22/11', 'Napoli')])).to be_nil
    end

    it 'adopts nothing when the FIN id is repeated on a row that could not lend it (cancelled, keyless)' do
      cancelled = csv_row('2026-12-13', 'Bari (BA)', '150105', cancelled: true)
      expect(adopted([csv_row('2026-11-22', 'Napoli (NA)', '150105'), cancelled], [watcher_row('22/11', 'Napoli')])).to be_nil
      keyless = csv_row('2026-12-13', '', '150105')
      expect(adopted([csv_row('2026-11-22', 'Napoli (NA)', '150105'), keyless], [watcher_row('22/11', 'Napoli')])).to be_nil
      expect(adopted([csv_row('2026-11-22', 'Napoli (NA)', '150105')], [watcher_row('22/11', 'Napoli')])).to be_present
    end

    it 'never lends a manifest download link, nor a link outside the FIN site' do
      manifest = csv_row('2026-11-22', 'Napoli (NA)', nil).merge('meetingUrl' => manifest_url('150105'))
      expect(adopted([manifest], [watcher_row('22/11', 'Napoli')])).to be_nil
      foreign = csv_row('2026-11-22', 'Napoli (NA)', nil).merge('meetingUrl' => 'https://evil.example.com/#/risultati/150105:x.html')
      expect(adopted([foreign], [watcher_row('22/11', 'Napoli')])).to be_nil
    end
  end

  describe 'self-check' do
    let(:extra_csv) { (1..7).map { |day| csv_row(format('2026-12-%02d', day), "City#{day} (XX)", "1502#{day.to_s.rjust(2, '0')}") } }
    let(:extra_rows) { (1..7).map { |day| watcher_row(format('%02d/12', day), "City#{day}", "1502#{day.to_s.rjust(2, '0')}") } }

    it 'adopts nothing and warns when more than 10 % of the comparable keys disagree' do
      write_calendar(linked_csv + [csv_row('2026-10-19', 'Quattro', '150004')] + extra_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows.first(2) + [watcher_row('18/10', 'Tre', '150999'), watcher_row('19/10', 'Quattro', '150998')] + extra_rows +
             [watcher_row('22/11', 'Napoli')]
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.resolve(rows)).to have_attributes(comparable: 11, disagreements: 2, suspended: true)
      expect(calendar.warnings(rows)).to eq([I18n.t('season_board.calendar_links.suspended', file: csv_name, count: 2, total: 11)])
    end

    it 'tolerates up to 10 % of disagreements, keeps the watcher link and names both ids' do
      write_calendar(linked_csv + extra_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows.first(2) + [watcher_row('18/10', 'Tre', '150999')] + extra_rows + [watcher_row('22/11', 'Napoli')]
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to have_attributes(fin_event_id: '150105')
      expect(calendar.link_for(rows[2], rows)).to be_nil
      expect(calendar.resolve(rows)).to have_attributes(comparable: 10, disagreements: 1, suspended: false)
      expect(calendar.warnings(rows)).to eq(
        [I18n.t('season_board.calendar_links.mismatch', watcher_id: '150999', calendar_id: '150003', date: '18/10', place: 'Tre', file: csv_name)]
      )
    end

    it 'adopts nothing and warns when fewer than MIN_COMPARABLE keys can be compared' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105')])
      rows = linked_rows.first(2) + [watcher_row('22/11', 'Napoli')]
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings(rows)).to eq([I18n.t('season_board.calendar_links.too_few', file: csv_name, total: 2, min: 3, count: 1)])
    end

    it 'says nothing when there is nothing to adopt' do
      write_calendar(linked_csv)
      expect(index.warnings(linked_rows)).to eq([])
      expect(index.warnings(linked_rows.first(1))).to eq([])
    end
  end

  describe 'calendar file' do
    let(:napoli) { [csv_row('2026-11-22', 'Napoli (NA)', '150105')] }
    let(:rows) { linked_rows + [watcher_row('22/11', 'Napoli')] }

    it 'adopts nothing without a calendar file' do
      calendar = index
      expect(calendar).not_to be_available
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.url_for('150105', rows)).to be_nil
      expect(calendar.warnings(rows)).to eq([])
    end

    it 'never raises on a malformed newer file and never falls back to an older one' do
      write_file('calendar.new', csv_name, "startURL,date,place\n\"broken,2026-11-22")
      write_calendar(linked_csv + napoli, name: '20261101-262-2-FIN-calendar.csv', folder: 'calendar.done')
      calendar = nil
      expect { calendar = index }.not_to raise_error
      expect(calendar).not_to be_available
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings).to contain_exactly(a_string_including(csv_name))
    end

    it 'never falls back past a newer file without data rows either' do
      write_calendar([])
      write_calendar(linked_csv + napoli, name: '20261120-262-2-FIN-calendar.csv', folder: 'calendar.done')
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings).to contain_exactly(a_string_including(csv_name, 'no data rows'))
    end

    it 'warns about a file without the expected columns' do
      write_file('calendar.new', csv_name, "a,b\n1,2\n")
      calendar = index
      expect(calendar).not_to be_available
      expect(calendar.warnings).to contain_exactly(a_string_including('meetingUrl'))
    end

    it 'reads the newest original file across calendar.new and calendar.done' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150100')], name: '20261102-262-2-FIN-calendar.csv')
      write_calendar(linked_csv + napoli, name: '20261120-262-2-FIN-calendar.csv', folder: 'calendar.done')
      calendar = index
      expect(calendar.file_path.to_s).to eq(path_for('calendar.done', '20261120-262-2-FIN-calendar.csv'))
      expect(calendar.url_for('150105', rows)).to eq(results_url('150105'))
    end

    it 'ignores the -sel- selections, the -skip leftovers and the other calendars' do
      write_calendar(linked_csv + napoli, name: '20261120-262-2-FIN-calendar.csv')
      write_calendar(linked_csv, name: '20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv')
      write_calendar(linked_csv, name: '20261125-262-2-FIN-calendar-sel-20261125-110734-892-skip.csv')
      write_calendar(linked_csv, name: '20261126-262-3-FIN-current-meetings.csv')
      calendar = index
      expect(calendar.file_path.basename.to_s).to eq('20261120-262-2-FIN-calendar.csv')
      expect(calendar.link_for(rows.last, rows)).to have_attributes(fin_event_id: '150105')
      expect(calendar.warnings).to eq([])
    end

    it "lends nothing from a file more than #{described_class::MAX_FILE_AGE.in_days.to_i} days older than the last watcher check" do
      write_calendar(linked_csv + napoli, name: '20261111-262-2-FIN-calendar.csv')
      expect(described_class.new(season:, data_dir:, as_of: Date.new(2026, 11, 25)).link_for(rows.last, rows)).to be_present
      calendar = described_class.new(season:, data_dir:, as_of: Time.zone.local(2026, 11, 26, 9, 30))
      expect(calendar).not_to be_available
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings).to eq(
        [I18n.t('season_board.calendar_links.too_old', file: '20261111-262-2-FIN-calendar.csv', season: '262', date: '11/11/2026', days: 14)]
      )
    end

    it "refuses the whole file of another sub-menu (e.g. 'Archivio', same file name)" do
      archive = 'https://www.federnuoto.it/home/master/circuito-supermaster/archivio-2012-2024/stagione-2023-2024.html'
      write_calendar(linked_csv + napoli + [csv_row('2026-11-29', 'Bari (BA)', '150106').merge('startURL' => archive)])
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings).to contain_exactly(a_string_including(csv_name, 'stagione-2023-2024'))
    end

    it 'refuses the whole file when a row falls outside the board season' do
      write_calendar(linked_csv + napoli + [csv_row('2026-09-10', 'Bari (BA)', '150106')])
      calendar = index
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings).to eq(
        [I18n.t('season_board.calendar_links.outside_season', file: csv_name, season: '262', row: 6, date: '2026-09-10')]
      )
      write_calendar(linked_csv + napoli + [csv_row('2026-09-20', 'Bari (BA)', '150106')]) # (within the margin)
      expect(index.link_for(rows.last, rows)).to have_attributes(fin_event_id: '150105')
    end

    it 'never raises on hostile rows: it skips them and reads the others' do
      long_date = csv_row("2026-11-29#{' ' * 200}x", 'Bari (BA)', '150106')
      allow(described_class).to receive(:normalize_places).and_call_original
      allow(described_class).to receive(:normalize_places).with('Boom (BB)').and_raise(Encoding::CompatibilityError, 'boom')
      write_calendar(linked_csv + napoli + [long_date, csv_row('2026-11-30', 'Boom (BB)', '150107')])
      calendar = nil
      expect { calendar = index }.not_to raise_error
      expect(calendar.link_for(rows.last, rows)).to have_attributes(fin_event_id: '150105')
      expect(calendar.warnings(rows)).to eq([])
    end

    it 'never raises while matching either' do
      write_calendar(linked_csv + napoli)
      calendar = index
      allow(FINEventId).to receive(:parse).and_raise(ArgumentError, 'kaboom')
      expect(calendar.link_for(rows.last, rows)).to be_nil
      expect(calendar.warnings(rows)).to contain_exactly(a_string_including('kaboom'))
    end
  end

  describe '#url_for' do
    it 'gives the adopted URL of a FIN id only' do
      write_calendar(linked_csv + [csv_row('2026-11-22', 'Napoli (NA)', '150105'), csv_row('2026-11-29', 'Bari (BA)', '150106')])
      rows = linked_rows + [watcher_row('22/11', 'Napoli')]
      calendar = index
      expect(calendar.url_for('150105', rows)).to eq(results_url('150105'))
      expect(calendar.url_for(150_105, rows)).to eq(results_url('150105'))
      expect(calendar.url_for('150001', rows)).to be_nil # on a watcher row: not adopted
      expect(calendar.url_for('150106', rows)).to be_nil # no watcher row on its key
      expect(calendar.adopted_fin_event_ids(rows)).to eq(['150105'])
    end
  end
end
