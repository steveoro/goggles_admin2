# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KpiRefreshJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:api_url) { 'http://kpi-api.test:8081' }
  let(:jwt) { 'background-jwt' }
  let(:key) { "kpi:#{api_url}" }
  let(:totals) { { 'users' => 87, 'import_queues' => 3, 'issues' => 12, 'api_daily_uses' => 1234 } }

  def stub_counter(endpoint, total: nil, status: 200, body: '[]')
    headers = total ? { 'Total' => total.to_s, 'Per-Page' => '1', 'Page' => '1' } : {}
    # (08: the import queue counter asks for the unfinished rows only)
    query = endpoint == 'import_queues' ? { per_page: '1', done: 'false' } : { per_page: '1' }
    WebMock.stub_request(:get, "#{api_url}/api/v3/#{endpoint}").with(query:)
           .to_return(status:, body:, headers:)
  end

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return(jwt)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'runs on the default queue, every 15 minutes' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
    recurring = YAML.load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring.dig('development', 'kpi_refresh'))
      .to eq('class' => 'KpiRefreshJob', 'queue' => 'default', 'schedule' => 'every 15 minutes')
  end

  it 'stores the four totals (per_page: 1, background JWT, short timeouts) under the URL-specific key' do
    stubs = totals.map { |endpoint, total| stub_counter(endpoint, total:) }
    allow(APIProxy).to receive(:call).and_call_original
    payload = described_class.perform_now

    expect(stubs).to all(have_been_requested.once)
    expect(APIProxy).to have_received(:call)
      .with(hash_including(method: :get, jwt:, params: { per_page: 1 }, open_timeout: 5, timeout: 10)).exactly(3).times
    # (only the unfinished import queue rows: applied SQL batches are kept 14 days on the server since 08)
    expect(APIProxy).to have_received(:call)
      .with(hash_including(method: :get, url: 'import_queues', params: { per_page: 1, done: false })).once
    snapshot = Ops::Snapshot.read(key)
    expect(snapshot.payload).to eq(payload)
    expect(payload).to include('url' => api_url, 'status' => 'ok', 'errors' => {},
                               'values' => { 'users' => 87, 'import_queues' => 3, 'issues' => 12, 'api_uses' => 1234 })
    expect(payload['fetched_at'].keys).to match_array(%w[users import_queues issues api_uses])
    expect(Ops::RemoteWrite.count).to eq(0) # (GET calls are never logged as remote writes)
  end

  it 'makes no call without valid credentials, keeping the previous values' do
    Ops::Snapshot.write!(key, { 'values' => { 'users' => 80 }, 'fetched_at' => { 'users' => '2026-11-23T09:00:00Z' } })
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return(nil)
    allow(APIProxy).to receive(:call)
    payload = described_class.perform_now
    expect(APIProxy).not_to have_received(:call)
    expect(payload).to include('status' => 'no_credentials', 'values' => { 'users' => 80 })
    expect(Ops::Snapshot.read(key).payload['fetched_at']).to eq('users' => '2026-11-23T09:00:00Z')
  end

  it 'keeps the old value of a counter that fails (status partial), refreshing the others' do
    Ops::Snapshot.write!(key, { 'values' => { 'users' => 80, 'issues' => 10 }, 'fetched_at' => { 'issues' => 'old' } })
    stub_counter('users', total: 87)
    stub_counter('import_queues', total: 3)
    stub_counter('issues', status: 500, body: { error: 'boom' }.to_json)
    stub_counter('api_daily_uses', total: 0)
    payload = described_class.perform_now
    expect(payload['status']).to eq('partial')
    expect(payload['values']).to eq('users' => 87, 'import_queues' => 3, 'issues' => 10, 'api_uses' => 0)
    expect(payload['fetched_at']['issues']).to eq('old')
    expect(payload['errors']).to eq('issues' => 'boom')
  end

  it 'treats a 2xx answer without the Total header as a failed counter' do
    stub_counter('users')
    %w[import_queues issues api_daily_uses].each { |endpoint| stub_counter(endpoint, total: 1) }
    payload = described_class.perform_now
    expect(payload['status']).to eq('partial')
    expect(payload['values']).not_to have_key('users')
    expect(payload['errors']['users']).to include('Total')
  end

  it 'stops at the first unreachable answer (status unreachable), keeping the previous values' do
    Ops::Snapshot.write!(key, { 'values' => { 'users' => 80 } })
    WebMock.stub_request(:get, /kpi-api\.test/).to_raise(Errno::ECONNREFUSED)
    payload = described_class.perform_now
    expect(WebMock).to have_requested(:get, /kpi-api\.test/).once
    expect(payload).to include('status' => 'unreachable', 'values' => { 'users' => 80 })
    expect(payload['errors']['users']).to include('API unreachable')
  end

  it 'records a 401 as unauthorized and stops' do
    stub_counter('users', status: 401, body: { error: 'Unauthorized' }.to_json)
    payload = described_class.perform_now
    expect(WebMock).to have_requested(:get, /kpi-api\.test/).once
    expect(payload['status']).to eq('unauthorized')
  end

  it 'keys the snapshot by API URL: another server has no data yet' do
    totals.each { |endpoint, total| stub_counter(endpoint, total:) }
    described_class.perform_now
    expect(described_class.read(api_url).payload['status']).to eq('ok')
    expect(described_class.read('http://another-api:8081')).to be_nil
    expect(described_class.key_for("#{api_url}/")).to eq(key)
  end

  it 'does nothing with the ops DB missing' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    allow(APIProxy).to receive(:call)
    expect(described_class.perform_now).to be_nil
    expect(APIProxy).not_to have_received(:call)
  end
end
