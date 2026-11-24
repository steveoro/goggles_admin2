# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemStatus::APISnapshot do
  let(:api_url) { 'http://localhost:8081' }

  after(:each) { Ops::Database.reset_state! }

  it 'uses one api.status:<base_url> key per URL (trailing slash ignored)' do
    expect(described_class.key_for("#{api_url}/")).to eq("api.status:#{api_url}")
  end

  it 'stores a successful ping with its version' do
    described_class.write!(api_url, DummyResponse.new(body: { msg: 'OK', version: '7.2' }.to_json), source: 'settings')
    snapshot = described_class.read(api_url)
    expect(snapshot.source).to eq('settings')
    expect(snapshot.payload).to eq('url' => api_url, 'reachable' => true, 'code' => 200, 'version' => '7.2',
                                   'msg' => 'OK', 'error' => nil, 'environment' => nil, 'capabilities' => nil)
  end

  it 'stores the environment and the capabilities reported by an API 0.10.81 or later (phase 08)' do
    body = { msg: 'OK', version: '7.3', environment: 'production', capabilities: %w[iq_batch_outcome db_fingerprint] }
    described_class.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
    expect(described_class.read(api_url).payload)
      .to include('environment' => 'production', 'capabilities' => %w[iq_batch_outcome db_fingerprint])

    # (a later 'status' answer without them, e.g. an API rolled back, drops them at once)
    described_class.write!(api_url, DummyResponse.new(body: { msg: 'OK', version: '7.2' }.to_json), source: 'system_status')
    expect(described_class.read(api_url).payload).to include('environment' => nil, 'capabilities' => nil)
  end

  it 'stores an unreachable server with its error detail' do
    result = APIProxy::Result.new(APIProxy::UnreachableResponse.new(api_url, Errno::ECONNREFUSED.new('nope')))
    described_class.write!(api_url, result, source: 'sign_in')
    payload = described_class.read(api_url).payload
    expect(payload).to include('reachable' => false, 'code' => 503, 'version' => nil)
    expect(payload['error']).to include('API unreachable')
  end

  it 'keeps the known version when a later reachable answer has none (e.g. the sign-in)' do
    body = { msg: 'OK', version: '7.2', environment: 'development', capabilities: %w[db_fingerprint] }
    described_class.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
    described_class.write!(api_url, DummyResponse.new(body: { jwt: 'x' }.to_json), source: 'sign_in')
    expect(described_class.read(api_url).payload)
      .to include('reachable' => true, 'version' => '7.2', 'environment' => 'development', 'capabilities' => %w[db_fingerprint])
  end

  it 'does nothing (and never raises) with the ops DB missing' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.write!(api_url, DummyResponse.new(body: '{}'), source: 'settings')).to be_nil
    expect(described_class.read(api_url)).to be_nil
  end
end
