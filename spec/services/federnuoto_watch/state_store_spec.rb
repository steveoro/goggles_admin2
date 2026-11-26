# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatch::StateStore do
  subject(:store) { described_class.new(path: state_path) }

  let(:tmp_dir) { Dir.mktmpdir('fin-watch-store') }
  let(:state_path) { File.join(tmp_dir, 'nested', 'state.json') }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it 'uses the configured path by default' do
    expect(described_class.new.path).to eq(Rails.root.join('tmp/federnuoto-watch.test.json'))
  end

  describe '#read' do
    it 'returns an empty Hash when the file is missing' do
      expect(store.read).to eq({})
    end

    it 'returns an empty Hash when the file is invalid' do
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, '{not json')
      expect(store.read).to eq({})
    end
  end

  describe '#update' do
    it 'creates the folder, saves & returns the state returned by the block' do
      result = store.update { |state| state.merge('digest' => 'abc') }
      expect(result).to eq('digest' => 'abc')
      expect(store.read).to eq('digest' => 'abc')
      expect(File.exist?("#{state_path}.tmp")).to be false
    end
  end

  describe '#pending_change & #acknowledge!' do
    before(:each) do
      store.update do |_state|
        { 'digest' => 'new', 'rows' => [{ 'key' => 'b' }], 'ack_digest' => 'old', 'ack_rows' => [{ 'key' => 'a' }],
          'change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'b' }] } }
      end
    end

    it 'returns the pending change until acknowledged' do
      expect(store.pending_change).to include('added' => [{ 'key' => 'b' }])
      store.acknowledge!
      expect(store.pending_change).to be_nil
    end

    it 'makes the latest snapshot the new acknowledged baseline' do
      state = store.acknowledge!
      expect(state).to include('ack_digest' => 'new', 'ack_rows' => [{ 'key' => 'b' }], 'change' => nil)
      expect(state['acknowledged_at']).to be_present
    end

    it 'acknowledges nothing (and writes nothing) when the expected digest is no longer the latest (0.10.103)' do
      mtime = File.mtime(state_path)
      expect(store.acknowledge!(expected_digest: 'old')).to be_nil
      expect(store.pending_change).to be_present
      expect(File.mtime(state_path)).to eq(mtime)
      expect(store.acknowledge!(expected_digest: 'new')).to include('ack_digest' => 'new')
    end
  end

  describe '.track_removed & .renamed? (0.10.103)' do
    def row(key, url: '', date: '08/11', place: 'Roma', year: '2026')
      { 'key' => key, 'name' => key, 'url' => url, 'date' => date, 'place' => place, 'year' => year }
    end

    let(:fin_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:m.html' }

    it 'keeps a row removed since it was first seen, with its removal time' do
      removed = described_class.track_removed([], [row('a', date: '01/12'), row('b', date: '02/12')], [row('b', date: '02/12')])
      expect(removed.pluck('key')).to eq(['a'])
      expect(removed.first['removed_at']).to be_present
    end

    it 'keeps the removal time of a known removed row, and drops a row listed again' do
      known = [row('a', date: '01/12').merge('removed_at' => '2026-11-01T10:00:00Z')]
      expect(described_class.track_removed(known, [], [row('c', date: '05/12')]).first['removed_at']).to eq('2026-11-01T10:00:00Z')
      expect(described_class.track_removed(known, [], [row('a', date: '01/12')])).to eq([])
    end

    it 'excludes the renames and the moves: same FIN id, or same dates and place under another key' do
      old_rows = [row('old-name', url: fin_url, date: '01/12'), row('old-place', date: '03/12', place: 'Napoli')]
      new_rows = [row('new-name', url: fin_url, date: '01/12'), row('new-place', date: '03/12', place: 'Napoli (NA)')]
      expect(described_class.track_removed([], old_rows, new_rows)).to eq([])
      expect(described_class.renamed?(old_rows.first, new_rows)).to be true
      expect(described_class.renamed?(row('x', date: '09/12'), new_rows)).to be false
    end

    it 'keeps at most MAX_REMOVED_ROWS, newest first' do
      known = (1..described_class::MAX_REMOVED_ROWS).map { |idx| row("k#{idx}", date: '01/12', place: "P#{idx}") }
      removed = described_class.track_removed(known, [row('new', date: '02/12', place: 'Q')], [])
      expect(removed.size).to eq(described_class::MAX_REMOVED_ROWS)
      expect(removed.first['key']).to eq('new')
    end
  end
end
