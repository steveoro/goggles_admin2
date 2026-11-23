# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemStatus::Registry do
  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    allow(APIProxy).to receive(:call)
    allow(APIProxy).to receive(:ping)
    allow(CrawlerClient).to receive(:new)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'lists the API, crawler, queue and FIN watcher probes, in order' do
    expect(described_class.probes.map(&:key)).to eq(%i[api crawler queue fin_watch])
    expect(described_class.snapshot_probes.map(&:key)).to eq(%i[api crawler])
  end

  describe '.results' do
    it 'returns one Result per probe without any network call' do
      results = described_class.results(api_url:)
      expect(results.map(&:key)).to eq(%i[api crawler queue fin_watch])
      expect(results).to all(be_a(SystemStatus::Result))
      expect(results.map(&:level)).to all(be_in(SystemStatus::Result::LEVELS))
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
      expect(CrawlerClient).not_to have_received(:new)
    end

    it 'never raises with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect(described_class.results(api_url:).map(&:level).first(2)).to eq(%i[unknown unknown])
    end
  end

  describe '.refresh_due?' do
    it 'is true while a snapshot is missing or older than 2 minutes' do
      expect(described_class.refresh_due?(api_url:)).to be true

      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true })
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => false })
      expect(described_class.refresh_due?(api_url:)).to be false

      Ops::Snapshot.find_by(key: 'system_status.crawler').update!(taken_at: 3.minutes.ago)
      expect(described_class.refresh_due?(api_url:)).to be true
    end
  end
end
