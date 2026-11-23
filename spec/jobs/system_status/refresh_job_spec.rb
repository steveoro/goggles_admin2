# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemStatus::RefreshJob do
  let(:api_url) { 'http://localhost:8081' }
  let(:crawler_client) { instance_double(CrawlerClient, status: { 'status' => 'OK, idle', 'detail' => '' }) }

  before(:each) do
    allow(APIProxy).to receive_messages(configured_base_url: api_url,
                                        ping: DummyResponse.new(body: { msg: 'OK', version: '7.2' }.to_json))
    allow(APIProxy).to receive(:call)
    allow(CrawlerClient).to receive(:new).and_return(crawler_client)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'runs on the default queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
  end

  it 'pings the API once (short timeouts), writes the api.status and system_status.crawler snapshots, and enqueues the drift check' do
    expect { expect(described_class.perform_now).to eq(%i[api crawler drift_v0]) }
      .to have_enqueued_job(DriftCheckJob).with(base_url: api_url)
    expect(APIProxy).to have_received(:ping).with(api_url, open_timeout: 3, timeout: 5).once
    expect(APIProxy).not_to have_received(:call)
    expect(Ops::Snapshot.read("api.status:#{api_url}").payload).to include('reachable' => true, 'version' => '7.2')
    expect(Ops::Snapshot.read('system_status.crawler').payload).to include('reachable' => true, 'status' => 'OK, idle')
  end

  it 'skips the snapshots refreshed less than a minute ago, unless forced' do
    Ops::Snapshot.write!("drift_v0:#{api_url}", { 'status' => 'ok' })
    described_class.perform_now
    expect(described_class.perform_now).to eq([])
    expect(APIProxy).to have_received(:ping).once
    expect(described_class.perform_now(force: true)).to eq(%i[api crawler drift_v0])
    expect(APIProxy).to have_received(:ping).twice
  end

  it 'asks for a drift check only when its snapshot is missing or older than 45 minutes' do
    Ops::Snapshot.write!("drift_v0:#{api_url}", { 'status' => 'ok' })
    expect { described_class.perform_now }.not_to have_enqueued_job(DriftCheckJob)
    Ops::Snapshot.find_by(key: "drift_v0:#{api_url}").update!(taken_at: 50.minutes.ago)
    expect { described_class.perform_now(force: true) }.to have_enqueued_job(DriftCheckJob)
  end

  it 'keeps going when a probe fails' do
    allow(CrawlerClient).to receive(:new).and_raise(RuntimeError, 'boom')
    expect(described_class.perform_now).to eq(%i[api drift_v0])
  end

  it 'does nothing with the ops DB missing' do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    expect(described_class.perform_now).to eq([])
    expect(APIProxy).not_to have_received(:ping)
  end

  it 'is scheduled every 5 minutes on the default queue' do
    recurring = YAML.load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring.dig('development', 'system_status_refresh'))
      .to eq('class' => 'SystemStatus::RefreshJob', 'queue' => 'default', 'schedule' => 'every 5 minutes')
  end
end
