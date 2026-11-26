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
    allow(Outbox).to receive(:data_root).and_return(data_root) # (rows loaded by the job: files moved under the temp root)
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

  describe 'with an API reporting the batch outcomes (phase 08)' do
    let(:capabilities) { %w[iq_batch_outcome iq_batch_filters db_fingerprint] }

    before(:each) do
      body = { msg: 'OK', version: '7.3', environment: 'production', capabilities: }
      SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
      allow(Ops::BackgroundCredentials).to receive(:jwt).and_return('a-valid-jwt')
    end

    def row_answer(done: false, process_runs: 0, error: nil)
      body = { 'id' => 1, 'batch_sql' => true, 'done' => done, 'process_runs' => process_runs, 'error_messages' => error }
      APIProxy::Result.new(DummyResponse.new(body: body.to_json))
    end

    it "turns an applied script into 'applied' at once (no 5-minute wait)" do
      script = sent_script('results.sent/262/0010-a-lt4.sql', pushed_at: 1.minute.ago)
      allow(APIProxy).to receive(:call).and_return(row_answer(done: true, process_runs: 1))
      expect(described_class.perform_now).to include('status' => 'ok', 'applied' => 1, 'outcomes' => true)
      expect(script.reload).to have_attributes(state: 'applied')
      expect(script.remote_outcome_at).to be_present
      expect(Ops::Event.last.kind).to eq('outbox.applied')
    end

    it "turns a failed script into 'failed' with the server error, moving its file back to results.new; the later ones stay queued" do
      failed = sent_script('results.sent/262/0010-a-lt4.sql')
      later = sent_script('results.sent/262/0011-b-lt4.sql')
      allow(APIProxy).to receive(:call).and_return(row_answer(process_runs: 1, error: 'ERROR 1062 (23000) at line 412: Duplicate entry'),
                                                   row_answer)
      expect(described_class.perform_now).to include('failed' => 1, 'checked' => 2)
      expect(failed.reload).to have_attributes(state: 'failed', rel_path: 'results.new/262/0010-a-lt4.sql')
      expect(failed.remote_error).to start_with('ERROR 1062')
      expect(data_root.join('results.new/262/0010-a-lt4.sql')).to exist
      expect(later.reload).to be_sent
      expect(later.failed_before).to eq([failed])
      expect(Ops::Event.find_by(kind: 'outbox.failed').level).to eq('error')
    end

    it 'refreshes the dashboard counters when an outcome changed, not when the scripts are still queued' do
      sent_script('results.sent/262/0010-a-lt4.sql')
      allow(APIProxy).to receive(:call).and_return(row_answer(process_runs: 1))
      expect { described_class.perform_now }.not_to have_enqueued_job(KpiRefreshJob)

      allow(APIProxy).to receive(:call).and_return(row_answer(done: true, process_runs: 1))
      expect { described_class.perform_now }.to have_enqueued_job(KpiRefreshJob)
    end

    it 'keeps a queued or running script as sent' do
      script = sent_script('results.sent/262/0010-a-lt4.sql')
      allow(APIProxy).to receive(:call).and_return(row_answer(process_runs: 1))
      described_class.perform_now
      expect(script.reload).to be_sent
      expect(script.remote_checked_at).to be_present
    end

    it "marks a vanished row 'missing_remote' (deleted on server), never 'executed_unreported'" do
      script = sent_script('results.sent/262/0010-a-lt4.sql')
      allow(APIProxy).to receive(:call).and_return(null_body)
      expect(described_class.perform_now).to include('missing' => 1, 'executed' => 0)
      expect(script.reload).to have_attributes(state: 'missing_remote')
    end

    it 'resolves an in-doubt script by its file checksum among the server batch rows' do
      script = create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', content: 'SELECT 42;', state: 'in_doubt',
                                                                              target_api_url: api_url, target_env: 'production')
      other = { 'id' => 9001, 'data_file_checksum' => 'nope==' }
      match = { 'id' => 9002, 'data_file_checksum' => Digest::MD5.base64digest('SELECT 42;') }
      allow(APIProxy).to receive(:call) do |options|
        next APIProxy::Result.new(DummyResponse.new(body: [other, match].to_json)) if options[:url] == 'import_queues'

        row_answer
      end
      expect(described_class.perform_now).to include('resolved' => 1)
      expect(APIProxy).to have_received(:call).with(hash_including(url: 'import_queues', params: { batch_sql: true, per_page: 100 }))
      expect(script.reload).to have_attributes(state: 'sent', remote_iq_id: 9002, rel_path: 'results.sent/262/0010-a-lt4.sql')
    end

    it 'leaves an in-doubt script without a matching row as it is' do
      script = create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', state: 'in_doubt', target_api_url: api_url)
      allow(APIProxy).to receive(:call).and_return(APIProxy::Result.new(DummyResponse.new(body: [].to_json)))
      described_class.perform_now
      expect(script.reload).to be_in_doubt
    end
  end
end
