# frozen_string_literal: true

require 'rails_helper'
require_relative 'disk_fixtures'

RSpec.describe SeasonBoard::DiskIndex do
  include SeasonBoardDiskFixtures

  subject(:index) { described_class.new(season_id: 262, data_dir:) }

  let(:data_dir) { Dir.mktmpdir('season-board-disk') }

  after(:each) { FileUtils.rm_rf(data_dir) }

  it 'is empty when no folder exists' do
    expect(index.entries).to eq({})
    expect(index.unmatched).to eq([])
    expect(index.for('150091')).to be_nil
  end

  describe 'results.new sources' do
    it 'maps an LT2 with results to its FIN id (read from the content, not the file name)' do
      lt2 = write_json('results.new', '2026-11-08-Anything_At_All.json', lt2_hash(fin_id: 150_091, results: true))
      entry = index.for(150_091)
      expect(entry.bases).to eq(['2026-11-08-Anything_At_All'])
      expect(entry.sources.size).to eq(1)
      expect(entry.results_source).to have_attributes(lt2_path: lt2, lt4_path: nil, has_results: true, meeting_only: false, phase: nil)
      expect(entry.results_source.review_path).to eq(lt2)
      expect(entry).to be_pending
      expect(entry.structure_source).to be_nil
      expect(entry.result_free_source).to be_nil
    end

    it 'detects a result-free LT2 (+ its result-free working copy)' do
      lt2 = write_json('results.new', 'm.json', lt2_hash(fin_id: 150_092))
      lt4 = write_json('results.new', 'm-lt4.json', lt4_hash)
      source = index.for('150092').result_free_source
      expect(source).to have_attributes(lt2_path: lt2, lt4_path: lt4, has_results: false, meeting_only: false)
      expect(source.review_path).to eq(lt2)
    end

    it 'reads the FIN id from a manifest URL only' do
      write_json('results.new', 'm.json', lt2_hash(fin_id: 150_093, manifest_only_url: true))
      expect(index.fin_event_ids).to eq(['150093'])
    end

    it 'detects a manifest-derived LT4 (meeting_only) without URLs through its LT2 sibling' do
      write_json('results.new', 'm.json', lt2_hash(fin_id: 150_094))
      lt4 = write_json('results.new', 'm-lt4.json', lt4_hash(meeting_only: true))
      entry = index.for('150094')
      expect(entry.structure_source).to have_attributes(lt4_path: lt4, meeting_only: true, has_results: false)
      expect(entry.result_free_source).to be_nil
    end

    it 'detects a manifest-derived LT4 carrying its own URLs (no LT2 sibling)' do
      lt4 = write_json('results.new', 'm-lt4.json', lt4_hash(fin_id: 150_095, meeting_only: true))
      expect(index.for('150095').structure_source.lt4_path).to eq(lt4)
    end

    it 'flags LT2 results + a meeting_only LT4 sibling (collision) as results' do
      lt2 = write_json('results.new', 'm.json', lt2_hash(fin_id: 150_096, results: true))
      write_json('results.new', 'm-lt4.json', lt4_hash(meeting_only: true))
      entry = index.for('150096')
      expect(entry.results_source).to have_attributes(lt2_path: lt2, has_results: true, meeting_only: true)
      expect(entry.structure_source).to be_nil
    end

    it 'treats a non -lt4 file with LT4 content as the LT4 source' do
      path = write_json('results.new', 'pdf-results.json', lt4_hash(fin_id: 150_097, results: true))
      expect(index.for('150097').results_source).to have_attributes(lt2_path: nil, lt4_path: path)
    end

    it 'collects the phase files, the highest phase & the review source' do
      write_json('results.new', 'm.json', lt2_hash(fin_id: 150_098, results: true))
      write_json('results.new', 'm-lt4.json', lt4_hash(results: true))
      phase1 = write_json('results.new', 'm-lt4-phase1.json', {})
      phase3 = write_json('results.new', 'm-lt4-phase3.json', {})
      entry = index.for('150098')
      expect(entry.phase).to eq(3)
      expect(entry.review_source.phase_paths).to eq(1 => phase1, 3 => phase3)
    end

    it 'ignores backup & committed copies' do
      write_json('results.new', 'm-lt4.orig.json', lt4_hash(fin_id: 150_099, results: true))
      write_json('results.new', 'm-lt4.orig-2.json', lt4_hash(fin_id: 150_099, results: true))
      write_json('results.new', 'm.committed.json', lt4_hash(fin_id: 150_099, results: true))
      expect(index.entries).to eq({})
    end

    it 'ignores the phase-file backups kept when a manifest copy is superseded' do
      write_json('results.new', 'm.json', lt2_hash(fin_id: 150_099, results: true))
      phase1 = write_json('results.new', 'm-lt4-phase1.json', {})
      write_json('results.new', 'm-lt4-phase1.orig.json', {})
      write_json('results.new', 'm-lt4-phase2.orig.json', {})
      write_json('results.new', 'm-lt4-phase3.orig-2.json', {})
      entry = index.for('150099')
      expect(entry.bases).to eq(['m'])
      expect(entry.review_source.phase_paths).to eq(1 => phase1)
      expect(index.unmatched).to eq([])
    end

    it 'groups several bases sharing the same FIN id' do
      write_json('results.new', 'a.json', lt2_hash(fin_id: 150_100, results: true))
      write_json('results.done', 'b-lt4.json', lt4_hash(fin_id: 150_100, meeting_only: true))
      entry = index.for('150100')
      expect(entry.bases).to contain_exactly('a', 'b')
      expect(entry).to be_archived
      expect(entry).to be_archived_meeting_only
    end
  end

  describe 'archives, SQL batches & manifests' do
    before(:each) do
      write_json('results.done', 'm.json', lt2_hash(fin_id: 150_101))
      write_json('results.done', 'm-lt4.json', lt4_hash(meeting_only: true))
      write_json('results.done', 'm-lt4-phase1.json', {})
    end

    it 'maps archived sources (FIN id from results.done content)' do
      entry = index.for('150101')
      expect(entry).to be_archived
      expect(entry.archived_paths).to contain_exactly(path_for('results.done', 'm.json'), path_for('results.done', 'm-lt4.json'))
      expect(entry.sources).to eq([])
      expect(entry).not_to be_pending
      expect(entry).to be_any_local
    end

    it 'maps the pending & the sent SQL batches of the same base' do
      sql_new = write_file('results.new', '0418-m-lt4.sql')
      sql_sent = write_file('results.sent', '0414-m-lt4.sql')
      write_file('results.sent', '0409-team_manager-10556-163.sql')
      entry = index.for('150101')
      expect(entry.sql_new_paths).to eq([sql_new])
      expect(entry.sql_sent_paths).to eq([sql_sent])
      expect(entry).to be_sql_pending
      expect(entry).to be_pending
    end

    it 'maps pending & extracted manifest PDFs' do
      pdf = write_file('manifests', 'manifest-m.pdf')
      write_file('manifests', 'manifest-m.txt')
      done_pdf = write_file('manifests.done', 'manifest-m.pdf')
      entry = index.for('150101')
      expect(entry.manifest_pdf_path).to eq(pdf)
      expect(entry).to be_manifest_pending
      expect(entry.manifest_done_paths).to eq([done_pdf])
    end
  end

  describe '#unmatched' do
    it 'lists pending bases without FIN id, ignoring archived ones' do
      ficr = write_json('results.new', 'ficr-lt4.json', lt4_hash(results: true).merge('meetingURL' => 'https://nuoto.ficr.it/#/NUO/x'))
      write_json('results.done', 'old-ficr-lt4.json', lt4_hash(results: true))
      pdf = write_file('manifests', '20261108-LAquila.pdf')
      expect(index.entries).to eq({})
      expect(index.unmatched.map(&:bases)).to contain_exactly(['20261108-LAquila'], ['ficr'])
      expect(index.unmatched.find { |e| e.bases == ['ficr'] }.results_source.lt4_path).to eq(ficr)
      expect(index.unmatched.find { |e| e.bases == ['20261108-LAquila'] }.manifest_pdf_path).to eq(pdf)
      expect(index.fin_event_id_for_base('ficr')).to be_nil
    end

    it 'excludes the board SQL scripts (backfill & calendar link) awaiting push, counting them apart' do
      backfill = write_file('results.new', '0420-season_board_backfill-262.sql')
      link = write_file('results.new', '0421-calendar_link-12345-150091.sql')
      write_file('results.sent', '0419-season_board_backfill-262.sql')
      expect(index.unmatched).to eq([])
      expect(index.entries).to eq({})
      expect(index.board_sql_paths).to eq([backfill, link])
    end
  end

  describe 'large files (bounded reads)' do
    before(:each) { stub_const('SeasonBoard::SourceProbe::FULL_PARSE_MAX_BYTES', 1024) }

    it 'reads the URLs from the head and assumes results' do
      hash = lt2_hash(fin_id: 150_102, results: true)
      hash['sections'] = Array.new(2000) { |i| { 'title' => "section #{i}", 'rows' => [{ 'name' => 'x' * 40 }] } }
      path = write_json('results.new', 'big.json', hash)
      expect(File.size(path)).to be > SeasonBoard::SourceProbe::CHUNK_BYTES * 2
      expect(index.for('150102').results_source).to have_attributes(lt2_path: path, has_results: true)
    end

    it 'reads meeting_only from the tail' do
      hash = lt4_hash(fin_id: 150_103, meeting_only: true)
      hash['events'] = Array.new(3000) { |i| { 'eventCode' => "E#{i}", 'eventDescription' => 'y' * 40, 'results' => [] } }
      path = write_json('results.new', 'big-lt4.json', hash)
      expect(File.size(path)).to be > SeasonBoard::SourceProbe::CHUNK_BYTES * 2
      expect(index.for('150103').structure_source).to have_attributes(lt4_path: path, meeting_only: true, has_results: false)
    end
  end

  it 'never parses archived sources in full (head/tail only)' do
    write_json('results.done', 'm.json', lt2_hash(fin_id: 150_104, results: true))
    resolver = DataFix::SourceResolver.new
    allow(resolver).to receive(:parsed_source_json).and_call_original
    described_class.new(season_id: 262, data_dir:, source_resolver: resolver).entries
    expect(resolver).not_to have_received(:parsed_source_json)
  end
end
