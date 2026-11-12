# frozen_string_literal: true

require 'rails_helper'
require_relative 'disk_fixtures'

RSpec.describe SeasonBoard::SourceProbe do
  include SeasonBoardDiskFixtures

  subject(:probe) { described_class.new }

  let(:data_dir) { Dir.mktmpdir('season-board-probe') }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def big_lt2(fin_id)
    lt2_hash(fin_id:, results: true).merge(
      'sections' => Array.new(2000) { |i| { 'title' => "section #{i}", 'rows' => [{ 'name' => 'x' * 40 }] } }
    )
  end

  describe '#call (small files, full parse)' do
    it 'reads the FIN id from the results URL, else from the manifest URL' do
      path = write_json('results.new', 'a.json', lt2_hash(fin_id: 150_091))
      expect(probe.call(path, full: true)).to eq(fin_event_id: '150091', meeting_only: false, has_results: false)
      path = write_json('results.new', 'b.json', lt2_hash(fin_id: 150_092, manifest_only_url: true))
      expect(probe.call(path, full: true)[:fin_event_id]).to eq('150092')
    end

    it 'detects results (LT2 sections rows / LT4 event results) & meeting_only' do
      lt2 = write_json('results.new', 'a.json', lt2_hash(results: true))
      lt4 = write_json('results.new', 'a-lt4.json', lt4_hash(meeting_only: true))
      expect(probe.call(lt2, full: true)).to include(has_results: true, fin_event_id: nil)
      expect(probe.call(lt4, full: true)).to include(has_results: false, meeting_only: true)
    end

    it 'ignores non-FIN URLs' do
      path = write_json('results.new', 'a-lt4.json', lt4_hash(results: true).merge('meetingURL' => 'https://nuoto.ficr.it/#/NUO/x'))
      expect(probe.call(path, full: true)[:fin_event_id]).to be_nil
    end

    it 'falls back to bounded reads on invalid JSON & never raises' do
      path = write_file('results.new', 'broken.json', %({"meetingURL":"#{results_url(150_093)}", "sections": [ ...))
      expect(probe.call(path, full: true)).to include(fin_event_id: '150093')
      expect(probe.call(File.join(data_dir, 'missing.json'), full: true)).to eq(fin_event_id: nil, meeting_only: false, has_results: false)
    end
  end

  describe '#call (bounded reads)' do
    it 'reads the URLs from the head of a large file and assumes results' do
      path = write_json('results.new', 'big.json', big_lt2(150_094))
      expect(File.size(path)).to be > described_class::CHUNK_BYTES * 2
      stub_const("#{described_class}::FULL_PARSE_MAX_BYTES", 1024)
      expect(probe.call(path, full: true)).to eq(fin_event_id: '150094', meeting_only: false, has_results: true)
    end

    it 'never reports results with full: false' do
      path = write_json('results.done', 'a.json', lt2_hash(fin_id: 150_095, results: true))
      expect(probe.call(path, full: false)).to eq(fin_event_id: '150095', meeting_only: false, has_results: false)
    end

    it 'unescapes JSON-escaped URLs' do
      path = write_file('results.done', 'a.json', %({"layoutType":2,"meetingURL":"#{results_url(150_096).gsub('/', '\\/')}"}))
      expect(probe.call(path, full: false)[:fin_event_id]).to eq('150096')
    end
  end

  it 'detects the layout type from the content' do
    expect(probe.layout_type(write_json('results.new', 'a.json', lt4_hash))).to eq(4)
    expect(probe.layout_type(write_json('results.new', 'b.json', lt2_hash))).to eq(2)
  end
end
