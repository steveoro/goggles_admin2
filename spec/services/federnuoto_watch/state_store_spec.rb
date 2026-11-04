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
  end
end
