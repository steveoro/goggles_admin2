# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DriftCheckJob do
  let(:api_url) { 'http://drift-api.test:8081' }
  let(:key) { "drift_v0:#{api_url}" }
  let(:endpoint_url) { "#{api_url}/api/v3/tools/latest_updates" }
  let(:meeting_ids) { GogglesDb::Meeting.order(updated_at: :desc).limit(3).pluck(:id) }
  let(:swimmer_ids) { GogglesDb::Swimmer.order(updated_at: :desc).limit(2).pluck(:id) }
  let(:missing_id) { GogglesDb::Meeting.maximum(:id) + 1000 }

  # Same shape as goggles_api 'tools/latest_updates' (table name => rows with id, updated_at & 1-2 columns)
  def latest_updates_body(extra_meeting_ids: [])
    {
      'meetings' => (meeting_ids + extra_meeting_ids).map { |id| { 'id' => id, 'updated_at' => Time.current.iso8601, 'description' => 'M' } },
      'swimmers' => swimmer_ids.map { |id| { 'id' => id, 'updated_at' => Time.current.iso8601, 'complete_name' => 'S' } },
      'unknown_table' => [{ 'id' => 1 }]
    }.to_json
  end

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('background-jwt')
  end

  after(:each) { Ops::Database.reset_state! }

  it 'runs on the default queue, every 30 minutes' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
    recurring = YAML.load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring.dig('development', 'drift_check'))
      .to eq('class' => 'DriftCheckJob', 'queue' => 'default', 'schedule' => 'every 30 minutes')
  end

  context 'when every remote ID exists locally and nothing was written remotely' do
    it 'stores an ok verdict (max: 10, background JWT, short timeouts)' do
      stub = WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }, headers: { 'Authorization' => 'Bearer background-jwt' })
                    .to_return(status: 200, body: latest_updates_body)
      allow(APIProxy).to receive(:call).and_call_original
      payload = described_class.perform_now

      expect(stub).to have_been_requested.once
      expect(APIProxy).to have_received(:call).with(hash_including(open_timeout: 5, timeout: 10))
      expect(payload).to include('url' => api_url, 'status' => 'ok', 'level' => 'ok', 'missing' => {}, 'missing_count' => 0,
                                 'checked_tables' => %w[meetings swimmers], 'remote_writes' => 0, 'error' => nil)
      expect(Ops::Snapshot.read(key).payload).to eq(payload)
      expect(Drift::V0Status.for(api_url)).to be_ok
    end
  end

  context 'with remote IDs missing locally' do
    it 'stores a warn verdict listing the missing IDs per table' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' })
             .to_return(status: 200, body: latest_updates_body(extra_meeting_ids: [missing_id]))
      payload = described_class.perform_now
      expect(payload).to include('status' => 'ok', 'level' => 'warn', 'missing' => { 'meetings' => [missing_id] },
                                 'missing_count' => 1)
      status = Drift::V0Status.for(api_url)
      expect(status.level).to eq(:warn)
      expect(status.reasons).to eq([:missing])
    end
  end

  context 'with remote-only writes since the last acknowledgement' do
    it 'stores a warn verdict counting them' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }).to_return(status: 200, body: latest_updates_body)
      FactoryBot.create(:ops_remote_write, base_url: api_url)
      payload = described_class.perform_now
      expect(payload).to include('status' => 'ok', 'level' => 'warn', 'remote_writes' => 1)
      expect(Drift::V0Status.for(api_url).reasons).to eq([:remote_writes])
    end
  end

  context 'when the verdict is unknown' do
    it 'makes no call without credentials' do
      allow(Ops::BackgroundCredentials).to receive(:jwt).and_return(nil)
      allow(APIProxy).to receive(:call)
      expect(described_class.perform_now).to include('status' => 'no_credentials', 'level' => 'unknown')
      expect(APIProxy).not_to have_received(:call)
    end

    it 'records an unreachable API' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }).to_raise(Errno::ECONNREFUSED)
      payload = described_class.perform_now
      expect(payload).to include('status' => 'unreachable', 'level' => 'unknown')
      expect(payload['error']).to include('API unreachable')
    end

    it 'records a 401 as unauthorized' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }).to_return(status: 401, body: { error: 'no' }.to_json)
      expect(described_class.perform_now).to include('status' => 'unauthorized', 'level' => 'unknown')
    end

    it 'records an API without the endpoint as unsupported' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }).to_return(status: 404, body: { error: 'Not Found' }.to_json)
      expect(described_class.perform_now).to include('status' => 'unsupported', 'level' => 'unknown')
    end

    it 'never raises on a local failure' do
      WebMock.stub_request(:get, endpoint_url).with(query: { max: '10' }).to_return(status: 200, body: latest_updates_body)
      allow(GogglesDb::Meeting).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished, 'down')
      expect(described_class.perform_now).to include('status' => 'error', 'level' => 'unknown')
    end
  end

  it 'does nothing with the ops DB missing' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    allow(APIProxy).to receive(:call)
    expect(described_class.perform_now).to be_nil
    expect(APIProxy).not_to have_received(:call)
  end
end
