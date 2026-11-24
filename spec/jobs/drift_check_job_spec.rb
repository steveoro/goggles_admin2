# frozen_string_literal: true

require 'rails_helper'

# The DB sync check job: read-only on both sides, the API answers are stubbed.
RSpec.describe DriftCheckJob do
  let(:api_url) { 'http://drift-api.test:8081' }

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('background-jwt')
  end

  after(:each) { Ops::Database.reset_state! }

  it 'runs on the default queue, every 30 minutes' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
    recurring = YAML.load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring.dig('development', 'drift_check'))
      .to eq('class' => 'DriftCheckJob', 'queue' => 'default', 'schedule' => 'every 30 minutes')
  end

  it "stores an 'unknown' check without any call against an API without the db_fingerprint capability (light local side), and pings the pages" do
    allow(Drift::Notifier).to receive(:ping)
    fingerprint = described_class.perform_now(trigger: 'manual')
    expect(fingerprint).to have_attributes(trigger: 'manual', mode: 'light', verdict: 'unknown', api_base_url: api_url)
    expect(fingerprint.local['tables']['laps']).to eq('max_id' => GogglesDb::Lap.maximum(:id))
    expect(Drift::Notifier).to have_received(:ping)
    expect(APIProxy).not_to have_received(:call)
  end

  it 'calls tools/db_fingerprint (background JWT) when the API offers it' do
    body = { msg: 'OK', version: '7.3', environment: 'production', capabilities: %w[db_fingerprint] }
    SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
    local = Drift::Fingerprint.local
    remote = { 'environment' => 'production', 'schema_version' => local['schema_version'], 'tables' => local['tables'] }
    allow(APIProxy).to receive(:call).and_return(APIProxy::Result.new(DummyResponse.new(body: remote.to_json)))
    fingerprint = described_class.perform_now
    expect(fingerprint).to have_attributes(verdict: 'green', target_env: 'production', trigger: 'schedule', mode: 'full')
    expect(fingerprint.local['tables']['laps']).to include('count' => GogglesDb::Lap.count)
    expect(APIProxy).to have_received(:call)
      .with(hash_including(method: :get, url: 'tools/db_fingerprint', jwt: 'background-jwt', base_url: api_url)).once
  end

  it 'does nothing with the ops DB missing' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.perform_now).to be_nil
  end

  it 'never writes the old drift v0 snapshot' do
    described_class.perform_now
    expect(Ops::Snapshot.where('key LIKE ?', 'drift_v0:%')).to be_empty
  end
end
