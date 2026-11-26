# frozen_string_literal: true

require 'rails_helper'

# Reads only the stored 'api.status:<url>' snapshot: never a network call.
RSpec.describe APICapabilities do
  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(APIProxy).to receive(:ping).and_raise('no API call expected')
  end

  after(:each) { Ops::Database.reset_state! }

  def store_status(body)
    SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
  end

  it 'reports the environment and the capabilities of an API 0.10.82 or later' do
    store_status(msg: 'OK', version: '7.3', environment: 'Production', capabilities: %w[iq_batch_outcome db_fingerprint])
    caps = described_class.for("#{api_url}/")
    expect(caps.environment).to eq('production')
    expect(caps.capabilities).to eq(%w[iq_batch_outcome db_fingerprint])
    expect(caps).to be_reported
    expect(caps.supports?(:db_fingerprint)).to be true
    expect(caps.supports?('iq_batch_filters')).to be false
    expect(caps.version).to eq('7.3')
    expect(caps.checked_at).to be_present
  end

  it 'reports nothing for an older API (no environment, no capability: the callers keep the phase 07 behaviour)' do
    store_status(msg: 'OK', version: '7.0')
    caps = described_class.for(api_url)
    expect(caps.environment).to be_nil
    expect(caps.capabilities).to eq([])
    expect(caps).not_to be_reported
    expect(caps.supports?(:iq_batch_outcome)).to be false
  end

  it 'reports nothing without a snapshot or with the ops DB missing' do
    expect(described_class.for(api_url).supports?(:db_fingerprint)).to be false
    store_status(msg: 'OK', capabilities: %w[db_fingerprint])
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.for(api_url).supports?(:db_fingerprint)).to be false
  end

  it 'defaults to the configured API' do
    allow(APIProxy).to receive(:configured_base_url).and_return("#{api_url}/")
    store_status(msg: 'OK', environment: 'development', capabilities: [])
    expect(described_class.for.environment).to eq('development')
  end
end
