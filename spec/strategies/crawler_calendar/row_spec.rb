# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe CrawlerCalendar::Row, type: :strategy do
  let(:headers) { %w[startURL date isCancelled name place meetingUrl year] }
  let(:data_root) { Pathname(Dir.mktmpdir('cal_row_spec')) }

  after(:each) { FileUtils.rm_rf(data_root) }

  def build_row(fields, season_id: 262, root: nil)
    hdrs = headers
    vals = hdrs.map { |h| fields[h] }
    csv_row = CSV::Row.new(hdrs, vals)
    described_class.new(csv_row: csv_row, index: 0, season_id: season_id, data_root: root || data_root)
  end

  describe '.normalize_text' do
    it 'converts word-ending apostrophes to accented vowels' do
      expect(described_class.normalize_text("Citta' di Mare")).to eq('Città di Mare')
      expect(described_class.normalize_text("Trofeo Citta'")).to eq('Trofeo Città')
    end

    it 'keeps apostrophes inside words' do
      expect(described_class.normalize_text("L'Aquila")).to eq("L'Aquila")
    end

    it 'keeps the degree symbol and strips CSV-hostile chars' do
      expect(described_class.normalize_text('25° Trofeo "X" / Y')).to eq('25° Trofeo X  Y')
    end

    it 'collapses whitespace and turns newlines into separators' do
      expect(described_class.normalize_text("Foo\nBar")).to eq('Foo; Bar')
      expect(described_class.normalize_text('Foo   Bar')).to eq('Foo Bar')
    end

    it 'returns empty string for nil' do
      expect(described_class.normalize_text(nil)).to eq('')
    end
  end

  describe '.parse_days_date' do
    it 'parses dd/mm' do
      expect(described_class.parse_days_date('24/10', '2026')).to eq(['2026-10-24'])
    end

    it 'parses dd-dd/mm into one date per day' do
      expect(described_class.parse_days_date('21-22/11', '2026')).to eq(%w[2026-11-21 2026-11-22])
    end

    it 'ports the FIN multi-month oddity verbatim' do
      expect(described_class.parse_days_date('31/10-8_11', '2026')).to eq(['2026-10-8_11-31'])
    end

    it 'splits ; -separated ISO dates (skip-file rows)' do
      expect(described_class.parse_days_date('2026-11-28; 2026-11-29', '2026'))
        .to eq(%w[2026-11-28 2026-11-29])
    end

    it 'returns a single ISO date as-is' do
      expect(described_class.parse_days_date('2026-12-13', '2026')).to eq(['2026-12-13'])
    end

    it 'returns an empty array when date or year is missing' do
      expect(described_class.parse_days_date('', '2026')).to eq([])
      expect(described_class.parse_days_date('24/10', '')).to eq([])
      expect(described_class.parse_days_date(nil, nil)).to eq([])
    end
  end

  describe '#cancelled?' do
    it 'is true only for literal true/canc (JS parity)' do
      expect(build_row({ 'isCancelled' => 'canc' }).cancelled?).to be(true)
      expect(build_row({ 'isCancelled' => 'true' }).cancelled?).to be(true)
      expect(build_row({ 'isCancelled' => 'annullata' }).cancelled?).to be(false)
      expect(build_row({ 'isCancelled' => nil }).cancelled?).to be(false)
      expect(build_row({ 'isCancelled' => '' }).cancelled?).to be(false)
    end
  end

  describe '#url? / #crawlable?' do
    it 'detects usable URLs with the same quirks as the JS crawler' do
      expect(build_row({ 'meetingUrl' => 'https://x' }).url?).to be(true)
      expect(build_row({ 'meetingUrl' => '' }).url?).to be(false)
      expect(build_row({ 'meetingUrl' => ' ' }).url?).to be(false)
      expect(build_row({ 'meetingUrl' => 'undefined' }).url?).to be(false)
      expect(build_row({ 'meetingUrl' => 'null' }).url?).to be(false)
    end

    it 'is crawlable only with a URL and not cancelled' do
      expect(build_row({ 'meetingUrl' => 'https://x' }).crawlable?).to be(true)
      expect(build_row({ 'meetingUrl' => 'https://x', 'isCancelled' => 'canc' }).crawlable?).to be(false)
      expect(build_row({ 'meetingUrl' => '' }).crawlable?).to be(false)
    end
  end

  describe '#manifest_basename / #manifest_filename' do
    it 'matches the crawler naming for a single-day meeting' do
      row = build_row({ 'date' => '24/10', 'year' => '2026', 'name' => 'Distanze Speciali Campania' })
      expect(row.manifest_basename).to eq('2026-10-24-Distanze_Speciali_Campania')
      expect(row.manifest_filename).to eq('manifest-2026-10-24-Distanze_Speciali_Campania.pdf')
    end

    it 'keeps degree symbols and apostrophes like the JS version' do
      row = build_row({ 'date' => '25/10', 'year' => '2026', 'name' => '25° Trofeo Città di Verolanuova' })
      expect(row.manifest_filename).to eq('manifest-2026-10-25-25°_Trofeo_Città_di_Verolanuova.pdf')
    end

    it 'uses the first date of a multi-day meeting' do
      row = build_row({ 'date' => '21-22/11', 'year' => '2026', 'name' => '7° Trofeo Gonzaga - Memorial Rascaroli' })
      expect(row.manifest_filename).to eq('manifest-2026-11-21-7°_Trofeo_Gonzaga_-_Memorial_Rascaroli.pdf')
    end

    it 'uses the "undefined" prefix for missing dates (JS quirk)' do
      row = build_row({ 'date' => '', 'year' => '', 'name' => 'Future Meeting' })
      expect(row.manifest_filename).to eq('manifest-undefined-Future_Meeting.pdf')
    end
  end

  describe '#manifest_state / #source_state' do
    let(:row) do
      build_row({ 'date' => '24/10', 'year' => '2026', 'name' => 'Distanze Speciali Campania' })
    end
    let(:basename) { '2026-10-24-Distanze_Speciali_Campania' }

    it 'is :none when no artifact exists' do
      expect(row.manifest_state).to eq(:none)
      expect(row.source_state).to eq(:none)
    end

    it 'is :pending when the pdf is under manifests/<season>' do
      dir = data_root.join('manifests/262')
      FileUtils.mkdir_p(dir)
      FileUtils.touch(dir.join("manifest-#{basename}.pdf"))
      expect(row.manifest_state).to eq(:pending)
      expect(row.source_state).to eq(:none)
    end

    it 'is :done when the pdf is under manifests.done/<season>' do
      dir = data_root.join('manifests.done/262')
      FileUtils.mkdir_p(dir)
      FileUtils.touch(dir.join("manifest-#{basename}.pdf"))
      expect(row.manifest_state).to eq(:done)
    end

    it 'detects lt4/json sources in results.new and results.done' do
      new_dir = data_root.join('results.new/262')
      done_dir = data_root.join('results.done/262')
      FileUtils.mkdir_p(new_dir)
      FileUtils.mkdir_p(done_dir)

      FileUtils.touch(new_dir.join("#{basename}.json"))
      expect(row.source_state).to eq(:json)

      FileUtils.touch(new_dir.join("#{basename}-lt4.json"))
      expect(row.source_state).to eq(:lt4)

      FileUtils.touch(done_dir.join("#{basename}.json"))
      expect(row.source_state).to eq(:done)
    end
  end
end
