# frozen_string_literal: true

require 'rails_helper'

# APIProxy is stubbed: read-only GETs only, never a real call.
RSpec.describe Outbox::RemoteStatusJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    allow(APIProxy).to receive(:configured_base_url).and_return(api_url)
    allow(APIProxy).to receive(:call)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def sent_script(rel_path, pushed_at: 10.minutes.ago, **attributes)
    create_sql_script(data_root, rel_path, state: 'sent', remote_iq_id: 700 + Ops::SqlScript.count, target_api_url: api_url,
                                           target_env: 'unknown', pushed_at:, **attributes)
  end

  def null_body
    APIProxy::Result.new(DummyResponse.new(body: 'null'))
  end

  it 'runs on the default queue and is recurring every 2 minutes' do
    expect(described_class.new.queue_name).to eq('default')
    recurring = YAML.safe_load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring['production']['outbox_remote_status']).to include('class' => 'Outbox::RemoteStatusJob', 'schedule' => 'every 2 minutes')
  end

  it 'returns at once without any call when nothing is sent' do
    create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql')
    expect(described_class.perform_now).to include('status' => 'idle')
    expect(APIProxy).not_to have_received(:call)
  end

  it "turns a script whose remote row is gone into 'executed_unreported', only after 5 minutes" do
    old = sent_script('results.sent/262/0010-a-lt4.sql')
    recent = sent_script('results.sent/262/0011-b-lt4.sql', pushed_at: 1.minute.ago)
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('a-valid-jwt')
    allow(APIProxy).to receive(:call).and_return(null_body)

    expect(described_class.perform_now).to include('status' => 'ok', 'checked' => 1, 'executed' => 1)
    expect(old.reload).to have_attributes(state: 'executed_unreported')
    expect(old.resolved_at).to be_present
    expect(recent.reload).to be_sent
    expect(APIProxy).to have_received(:call).with(hash_including(method: :get, url: "import_queue/#{old.remote_iq_id}", jwt: 'a-valid-jwt'))
    expect(Ops::Event.last.kind).to eq('outbox.executed_unreported')
  end

  it 'keeps a script whose remote row is still there, noting the check time' do
    script = sent_script('results.sent/262/0010-a-lt4.sql')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('a-valid-jwt')
    allow(APIProxy).to receive(:call).and_return(APIProxy::Result.new(DummyResponse.new(body: { id: script.remote_iq_id }.to_json)))
    described_class.perform_now
    expect(script.reload).to be_sent
    expect(script.remote_checked_at).to be_present
  end

  it "changes nothing with an expired JWT ('sign in to refresh')" do
    script = sent_script('results.sent/262/0010-a-lt4.sql')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return(nil)
    expect(described_class.perform_now).to include('status' => 'no_credentials')
    expect(script.reload).to be_sent
    expect(APIProxy).not_to have_received(:call)
    expect(described_class.read.payload['status']).to eq('no_credentials')
  end

  it 'skips the scripts pushed to another API' do
    sent_script('results.sent/262/0010-a-lt4.sql', target_api_url: 'http://other:447')
    allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('a-valid-jwt')
    expect(described_class.perform_now).to include('status' => 'idle')
  end

  describe '.enqueue_if_due' do
    it 'enqueues only with sent scripts and no recent check' do
      expect(described_class.enqueue_if_due).to be false
      sent_script('results.sent/262/0010-a-lt4.sql')
      expect { described_class.enqueue_if_due }.to have_enqueued_job(described_class)
      Ops::Snapshot.write!(described_class::SNAPSHOT_KEY, { 'status' => 'ok' })
      expect(described_class.enqueue_if_due).to be false
    end
  end
end
