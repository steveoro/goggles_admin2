# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe CrawlerCalendar::Sheet, type: :strategy do
  let(:fixture_path) { file_fixture('files/calendar_sample.csv').to_s }
  let(:sheet) { described_class.new(fixture_path, season_id: 262) }

  describe '#initialize' do
    it 'parses the CSV headers and wraps each row' do
      expect(sheet.headers).to eq(%w[startURL date isCancelled name place meetingUrl year])
      expect(sheet.row_count).to eq(10)
      expect(sheet.rows).to all(be_a(CrawlerCalendar::Row))
    end

    it 'exposes per-row derived fields' do
      expect(sheet.rows.first.name).to eq('Distanze Speciali Campania')
      expect(sheet.rows.first.dates).to eq(['2026-10-24'])
      expect(sheet.rows[5].url?).to be(false) # 9° Sardinia in Water, empty meetingUrl
      expect(sheet.rows[8].cancelled?).to be(true) # Cancelled Trophy, isCancelled = canc
    end
  end

  describe '#subset_csv' do
    it 'emits the same headers and only the selected rows' do
      csv = sheet.subset_csv([0, 4])
      reparsed = CSV.parse(csv, headers: true)
      expect(reparsed.headers).to eq(sheet.headers)
      expect(reparsed.size).to eq(2)
      expect(reparsed['name'])
        .to eq(['Distanze Speciali Campania', '7° Trofeo Gonzaga - Memorial Rascaroli'])
    end

    it 'preserves verbatim field values (quoting normalized but fields identical)' do
      csv = sheet.subset_csv([2])
      row = CSV.parse(csv, headers: true).first
      expect(row['date']).to eq('31/10-8_11')
      expect(row['meetingUrl']).to eq('https://www.federnuoto.it/event/150170')
    end

    it 'ignores out-of-range and duplicate indexes' do
      csv = sheet.subset_csv([1, 1, 99])
      expect(CSV.parse(csv, headers: true).size).to eq(1)
    end
  end

  describe '#write_subset' do
    let(:tmp_dir) { Dir.mktmpdir('cal_sheet_spec') }

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    it 'writes a -sel- CSV next to the source file and returns its path' do
      src = File.join(tmp_dir, 'test-cal.csv')
      FileUtils.cp(fixture_path, src)
      dest = described_class.new(src, season_id: 262).write_subset([0, 9])

      expect(File).to exist(dest)
      expect(File.basename(dest)).to match(/\Atest-cal-sel-\d{8}-\d{6}-\d{3}\.csv\z/)
      expect(File.dirname(dest)).to eq(tmp_dir)

      reparsed = CSV.read(dest, headers: true)
      expect(reparsed.size).to eq(2)
      expect(reparsed['name'])
        .to eq(['Distanze Speciali Campania', 'Half-Cancelled Meeting'])
    end
  end
end
