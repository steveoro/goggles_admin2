# frozen_string_literal: true

require 'rails_helper'

# APIProxy is stubbed: the remote fingerprint is a canned answer, never a real call.
RSpec.describe Drift::Check do
  let(:api_url) { 'http://localhost:8081' }
  let(:local_light) { Drift::Fingerprint.local(light: true) }

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('background-jwt')
  end

  after(:each) { Ops::Database.reset_state! }

  def store_capabilities(*names)
    body = { msg: 'OK', version: '7.3', environment: 'development', capabilities: names }
    SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
  end

  # The remote answer mirroring the local DB (max ids only, as in light mode).
  def mirror_answer(overrides = {})
    tables = local_light['tables'].merge(overrides)
    body = { 'environment' => 'development', 'schema_version' => local_light['schema_version'],
             'import_queue' => { 'batch_failed' => 0 }, 'tables' => tables }
    APIProxy::Result.new(DummyResponse.new(body: body.to_json))
  end

  it "stores an 'unknown' check without any call against an API without the db_fingerprint capability" do
    store_capabilities('iq_batch_outcome')
    fingerprint = described_class.call(trigger: 'gate', mode: 'light')
    expect(fingerprint).to be_persisted
    expect(fingerprint).to have_attributes(verdict: 'unknown', trigger: 'gate', mode: 'light', api_base_url: api_url,
                                           target_env: 'development', api_version: '7.3')
    expect(fingerprint.reasons.pluck('code')).to eq(%w[no_capability])
    expect(fingerprint.local['tables'].keys).to eq(Drift::Tables.all)
    expect(APIProxy).not_to have_received(:call)
  end

  it 'reads the local side in light mode when the remote side cannot be compared (no capability, or no JWT)' do
    expect(described_class.call(mode: 'full')).to have_attributes(mode: 'light', verdict: 'unknown')
    store_capabilities('db_fingerprint')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return(nil)
    fingerprint = described_class.call(mode: 'full')
    expect(fingerprint).to have_attributes(mode: 'light', verdict: 'unknown')
    expect(fingerprint.reasons.pluck('code')).to eq(%w[no_credentials])
    expect(APIProxy).not_to have_received(:call)
  end

  it 'compares with the remote fingerprint and stores a green verdict when they match' do
    store_capabilities('db_fingerprint')
    allow(APIProxy).to receive(:call).and_return(mirror_answer)
    fingerprint = described_class.call(mode: 'light')
    expect(fingerprint).to have_attributes(verdict: 'green', schema_version_remote: local_light['schema_version'])
    expect(APIProxy).to have_received(:call).with(hash_including(url: 'tools/db_fingerprint', jwt: 'background-jwt', base_url: api_url))
  end

  it 'stores a red verdict when the remote laps max id is above the local one, recording the change as an event' do
    store_capabilities('db_fingerprint')
    allow(APIProxy).to receive(:call).and_return(mirror_answer('laps' => { 'max_id' => local_light['tables']['laps']['max_id'].to_i + 5 }))
    FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 1.hour.ago)
    fingerprint = described_class.call(mode: 'light')
    expect(fingerprint.verdict).to eq('red')
    expect(fingerprint.reasons.first).to include('code' => 'id_collision', 'table' => 'laps')
    event = Ops::Event.where(kind: 'drift.verdict_changed').last
    expect(event.data).to include('from' => 'green', 'to' => 'red')
    expect(event.link_path).to eq('/db_sync')
  end

  it 'counts the remote-only data writes since the last green check or acknowledgement (not the import queue actions)' do
    store_capabilities('db_fingerprint')
    allow(APIProxy).to receive(:call).and_return(mirror_answer)
    FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 2.hours.ago)
    FactoryBot.create(:ops_remote_write, base_url: api_url, created_at: 3.hours.ago)
    FactoryBot.create(:ops_remote_write, base_url: api_url, created_at: 1.hour.ago)
    FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'import_queue/9123', http_method: 'delete', created_at: 1.hour.ago)
    FactoryBot.create(:ops_remote_write, base_url: api_url, status_code: 500, created_at: 1.hour.ago)
    fingerprint = described_class.call(mode: 'light')
    expect(fingerprint).to have_attributes(verdict: 'amber', remote_writes_count: 1)

    Ops::RemoteWrite.acknowledge!
    expect(described_class.call(mode: 'light')).to have_attributes(verdict: 'green', remote_writes_count: 0)
  end

  it 'keeps only the last 200 checks' do
    store_capabilities
    stub_const('Ops::DbFingerprint::KEEP', 2)
    3.times { |i| FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: (i + 1).hours.ago) }
    described_class.call(mode: 'light')
    expect(Ops::DbFingerprint.count).to eq(2)
  end

  it 'does nothing without the ops DB' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.call).to be_nil
  end
end
