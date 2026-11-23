# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::APITarget do
  let(:url) { 'http://localhost:8081' }

  after(:each) { Ops::Database.reset_state! }

  describe '#guess' do
    it 'is :production only for a URL ending with port 447' do
      expect(described_class.new(url: 'https://master-goggles.org:447').guess).to eq(:production)
      expect(described_class.new(url: 'https://master-goggles.org:447/').guess).to eq(:production)
    end

    it 'is :unknown for any other URL and never says staging' do
      %w[https://master-goggles.org:446 http://localhost:8081 https://master-goggles.org https://x.org:4470].each do |other|
        guess = described_class.new(url: other).guess
        expect(guess).to eq(:unknown)
        expect(guess.to_s).not_to match(/staging/i)
      end
    end
  end

  describe '.current' do
    it 'uses the configured API URL (local DB setting, no API call)' do
      allow(APIProxy).to receive(:call)
      allow(APIProxy).to receive(:ping)
      allow(APIProxy).to receive(:configured_base_url).and_return("#{url}/")
      target = described_class.current
      expect(target.url).to eq(url)
      expect(target.reachability).to be_a(Symbol)
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
    end
  end

  describe 'labels' do
    it 'round-trips a label per URL, removing it when blank' do
      expect(described_class.store_label!(url, '  Local   copy ')).to be true
      expect(described_class.store_label!('https://master-goggles.org:447', 'Production')).to be true
      expect(described_class.new(url:).label).to eq('Local copy')
      expect(described_class.new(url: 'https://master-goggles.org:447').label).to eq('Production')

      expect(described_class.store_label!("#{url}/", '')).to be true
      expect(described_class.new(url:).label).to be_nil
      expect(described_class.labels).to eq('https://master-goggles.org:447' => 'Production')
    end

    it 'refuses a blank URL' do
      expect(described_class.store_label!('', 'x')).to be false
    end
  end

  describe '#reachability' do
    it 'is :unknown without a snapshot' do
      target = described_class.new(url:)
      expect(target.reachability).to eq(:unknown)
      expect(target.taken_at).to be_nil
    end

    it 'reads the api.status snapshot' do
      Ops::Snapshot.write!("api.status:#{url}", { 'reachable' => true, 'code' => 200, 'version' => '7.1' })
      target = described_class.new(url:)
      expect(target.reachability).to eq(:reachable)
      expect(target.version).to eq('7.1')
      expect(target.taken_at).to be_within(5.seconds).of(Time.current)

      Ops::Snapshot.write!("api.status:#{url}", { 'reachable' => false, 'code' => 503, 'error' => 'down' })
      target = described_class.new(url:)
      expect(target.reachability).to eq(:unreachable)
      expect(target.error).to eq('down')
    end

    it 'is :unreachable in an API-offline session, with the session time' do
      Ops::Snapshot.write!("api.status:#{url}", { 'reachable' => true, 'code' => 200 })
      at = 10.minutes.ago.change(usec: 0)
      target = described_class.new(url:, offline_info: { 'url' => url, 'reason' => 'refused', 'at' => at.iso8601 })
      expect(target).to be_offline
      expect(target.reachability).to eq(:unreachable)
      expect(target.taken_at).to eq(at)
      expect(target.error).to eq('refused')
    end
  end

  context 'with the ops DB missing' do
    before(:each) { allow(Ops::Database).to receive(:state).and_return(:missing) }

    it 'has no label and an :unknown reachability, without raising' do
      target = described_class.new(url:)
      expect(target.label).to be_nil
      expect(target.reachability).to eq(:unknown)
      expect(described_class.labels).to eq({})
      expect(described_class.store_label!(url, 'x')).to be false
    end
  end
end
