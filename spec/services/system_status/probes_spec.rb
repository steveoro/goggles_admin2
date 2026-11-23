# frozen_string_literal: true

require 'rails_helper'

# Every probe returns a SystemStatus::Result and never raises; snapshot probes read only their Ops::Snapshot.
RSpec.describe 'SystemStatus probes' do # rubocop:disable RSpec/DescribeClass
  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    allow(APIProxy).to receive(:call)
    allow(APIProxy).to receive(:ping)
    allow(CrawlerClient).to receive(:new)
  end

  after(:each) { Ops::Database.reset_state! }

  shared_examples_for 'a probe that never raises' do
    it 'returns an :unknown result when its source raises' do
      allow_any_instance_of(probe_class).to receive(:evaluate).and_raise(RuntimeError, 'boom') # rubocop:disable RSpec/AnyInstance
      result = probe_class.new(api_url:).call
      expect(result).to be_a(SystemStatus::Result)
      expect(result.level).to eq(:unknown)
      expect(result.label).to eq(I18n.t(probe_class.label_key))
    end
  end

  shared_examples_for 'a snapshot probe that never touches the network while evaluated' do
    it 'reads only its snapshot' do
      probe_class.new(api_url:).call
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
      expect(CrawlerClient).not_to have_received(:new)
    end

    it 'is :unknown with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect(probe_class.new(api_url:).call.level).to eq(:unknown)
    end
  end

  describe SystemStatus::APIProbe do
    let(:probe_class) { described_class }

    it_behaves_like 'a probe that never raises'
    it_behaves_like 'a snapshot probe that never touches the network while evaluated'

    it 'has key :api in snapshot mode, reading the api.status:<url> snapshot' do
      expect(described_class.key).to eq(:api)
      expect(described_class.mode).to eq(:snapshot)
      expect(described_class.new(api_url: "#{api_url}/").snapshot_key).to eq("api.status:#{api_url}")
    end

    it 'is :unknown without a snapshot' do
      expect(described_class.new(api_url:).call.level).to eq(:unknown)
    end

    it 'is :ok for a reachable server, :error for an unreachable one' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200, 'version' => '7.1' })
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:ok)
      expect(result.detail).to include('7.1')
      expect(result.checked_at).to be_present

      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => false, 'code' => 503, 'error' => 'refused' })
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:error)
      expect(result.detail).to include('refused')
      expect(result.action[:path]).to eq('/settings')
    end

    it 'is :ok for a reachable server answering below 500 (e.g. rejected credentials), :warn for a 5xx' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 401, 'error' => 'Unauthorized' })
      expect(described_class.new(api_url:).call.level).to eq(:ok)
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 500, 'error' => 'Oops' })
      expect(described_class.new(api_url:).call.level).to eq(:warn)
    end

    it 'is :unknown for a stale snapshot' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200 })
      Ops::Snapshot.find_by(key: "api.status:#{api_url}").update!(taken_at: 1.hour.ago)
      expect(described_class.new(api_url:).call.level).to eq(:unknown)
    end

    it 'is :error in an API-offline session, whatever the snapshot says' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200 })
      result = described_class.new(api_url:, offline: true).call
      expect(result.level).to eq(:error)
      expect(result.detail).to eq(I18n.t('shell.status.api.offline'))
    end

    describe '#refresh!' do
      it 'pings the API once, with short timeouts, and writes the api.status snapshot' do
        allow(APIProxy).to receive(:ping).with(api_url, open_timeout: 3, timeout: 5)
                                         .and_return(DummyResponse.new(body: { msg: 'OK', version: '7.2' }.to_json))
        described_class.new(api_url:).refresh!
        expect(APIProxy).to have_received(:ping).once
        snapshot = Ops::Snapshot.read("api.status:#{api_url}")
        expect(snapshot.payload).to include('reachable' => true, 'code' => 200, 'version' => '7.2')
      end
    end
  end

  describe SystemStatus::CrawlerProbe do
    let(:probe_class) { described_class }

    it_behaves_like 'a probe that never raises'
    it_behaves_like 'a snapshot probe that never touches the network while evaluated'

    it 'reports a crawler that is not running as :unknown ("off"), with a link to the crawler page' do
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => false })
      result = described_class.new.call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('shell.status.crawler.off'))
      expect(result.action[:path]).to eq('/pull/index')
    end

    it 'reports an idle crawler as :ok and a failed run as :warn' do
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => true, 'status' => 'OK, idle', 'detail' => '' })
      expect(described_class.new.call.level).to eq(:ok)
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => true, 'status' => 'ERROR', 'detail' => 'Timeout' })
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.detail).to include('Timeout')
    end

    describe '#refresh!' do
      it 'asks the crawler for its status with short timeouts and stores it' do
        client = instance_double(CrawlerClient, status: { 'status' => 'OK, running', 'detail' => 'x', 'progress' => 2, 'total' => 5 })
        allow(CrawlerClient).to receive(:new).with(timeout: 2, open_timeout: 1).and_return(client)
        described_class.new.refresh!
        expect(Ops::Snapshot.read('system_status.crawler').payload)
          .to include('reachable' => true, 'status' => 'OK, running', 'progress' => 2, 'total' => 5)
      end

      it 'stores an unreachable crawler' do
        allow(CrawlerClient).to receive(:new).and_return(instance_double(CrawlerClient, status: nil))
        described_class.new.refresh!
        expect(Ops::Snapshot.read('system_status.crawler').payload).to eq('reachable' => false)
      end
    end
  end

  describe SystemStatus::QueueProbe do
    let(:probe_class) { described_class }

    it_behaves_like 'a probe that never raises'

    it 'is inline' do
      expect(described_class.mode).to eq(:inline)
    end

    it 'is :unknown when Solid Queue is not the job adapter (test environment), without raising' do
      result = described_class.new.call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('shell.status.queue.not_in_use'))
    end

    context 'with Solid Queue as the job adapter' do
      before(:each) do
        allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:solid_queue)
      end

      it 'is :ok when a process sent a recent heartbeat' do
        allow(described_class).to receive(:live_process_count).and_return(3)
        result = described_class.new.call
        expect(result.level).to eq(:ok)
        expect(result.detail).to include('3')
        expect(described_class).to have_received(:live_process_count).with(since: be_within(5.seconds).of(5.minutes.ago))
      end

      it 'is :error when no process is alive' do
        allow(described_class).to receive(:live_process_count).and_return(0)
        expect(described_class.new.call.level).to eq(:error)
      end

      it 'is :unknown when the queue DB/tables are missing (no exception)' do
        allow(described_class).to receive(:live_process_count).and_raise(ActiveRecord::StatementInvalid, 'no such table')
        expect { described_class.new.call }.not_to raise_error
        expect(described_class.new.call.level).to eq(:unknown)
      end
    end
  end

  describe SystemStatus::FINWatchProbe do
    let(:probe_class) { described_class }
    let(:store) { FedernuotoWatch::StateStore.new }

    before(:each) { FileUtils.rm_f(store.path) }
    after(:each) { FileUtils.rm_f(store.path) }

    it_behaves_like 'a probe that never raises'

    it 'has key :fin_watch, inline' do
      expect(described_class.key).to eq(:fin_watch)
      expect(described_class.mode).to eq(:inline)
    end

    it 'is :unknown when the watcher never ran' do
      expect(described_class.new.call.level).to eq(:unknown)
    end

    it 'is :ok after a check without pending changes' do
      store.update { |state| state.merge('last_checked' => Time.current.iso8601) }
      expect(described_class.new.call.level).to eq(:ok)
    end

    it 'is :warn with a pending change, linking to the Season board' do
      store.update do |state|
        state.merge('last_checked' => Time.current.iso8601,
                    'change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'name' => 'X' }] })
      end
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.action[:path]).to eq('/season_board')
    end

    it 'is :warn when the last check failed' do
      store.update { |state| state.merge('last_checked' => Time.current.iso8601, 'last_error' => 'FetchError: 503') }
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.detail).to include('503')
    end
  end

  describe SystemStatus::DriftV0Probe do
    include ActiveSupport::Testing::TimeHelpers

    let(:probe_class) { described_class }
    let(:snapshot_key) { "drift_v0:#{api_url}" }

    def drift_payload(status: 'ok', missing: {})
      { 'url' => api_url, 'status' => status, 'missing' => missing, 'missing_count' => missing.values.sum(&:size),
        'checked_tables' => %w[meetings], 'error' => status == 'ok' ? nil : 'some error' }
    end

    it_behaves_like 'a probe that never raises'
    it_behaves_like 'a snapshot probe that never touches the network while evaluated'

    it 'has key :drift_v0 in snapshot mode, reading the drift_v0:<url> snapshot' do
      expect(described_class.key).to eq(:drift_v0)
      expect(described_class.mode).to eq(:snapshot)
      expect(described_class.new(api_url: "#{api_url}/").snapshot_key).to eq(snapshot_key)
      expect(I18n.t(described_class.label_key, locale: :en)).to eq('DB sync')
    end

    it 'is :unknown ("not checked yet") without a snapshot' do
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('shell.status.drift_v0.never'))
    end

    it 'is :ok when every remote ID exists locally and nothing was written remotely' do
      Ops::Snapshot.write!(snapshot_key, drift_payload)
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:ok)
      expect(result.action).to be_nil
    end

    it 'is :warn with remote IDs missing locally, linking to /remote_writes' do
      Ops::Snapshot.write!(snapshot_key, drift_payload(missing: { 'meetings' => [1, 2] }))
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:warn)
      expect(result.detail).to include('meetings: 2')
      expect(result.action[:path]).to eq('/remote_writes')
    end

    it 'is :warn with unacknowledged remote writes to the same API (live count), until acknowledged' do
      Ops::Snapshot.write!(snapshot_key, drift_payload)
      FactoryBot.create(:ops_remote_write, base_url: api_url)
      FactoryBot.create(:ops_remote_write, base_url: 'http://other-api:8081')
      FactoryBot.create(:ops_remote_write, base_url: api_url, status_code: 500)
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:warn)
      expect(result.detail).to eq(I18n.t('shell.status.drift_v0.remote_writes', count: 1))

      travel(1.second) { Ops::RemoteWrite.acknowledge! }
      travel(2.seconds) { expect(described_class.new(api_url:).call.level).to eq(:ok) }
    end

    it 'is :unknown when the check had no credentials, could not reach the API or is stale' do
      Ops::Snapshot.write!(snapshot_key, drift_payload(status: 'no_credentials'))
      expect(described_class.new(api_url:).call.detail).to eq(I18n.t('shell.status.drift_v0.no_credentials'))
      Ops::Snapshot.write!(snapshot_key, drift_payload(status: 'unreachable'))
      expect(described_class.new(api_url:).call.level).to eq(:unknown)

      Ops::Snapshot.write!(snapshot_key, drift_payload(missing: { 'meetings' => [1] }))
      snapshot = Ops::Snapshot.find_by(key: snapshot_key)
      snapshot.update!(taken_at: 2.hours.ago)
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('shell.status.drift_v0.stale', time: I18n.l(snapshot.taken_at.localtime, format: :short)))
    end

    describe '#refresh_due? and #refresh!' do
      it 'is due only without a snapshot or past 45 minutes, whatever the shorter max age' do
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be true
        Ops::Snapshot.write!(snapshot_key, drift_payload)
        Ops::Snapshot.find_by(key: snapshot_key).update!(taken_at: 30.minutes.ago)
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be false
        Ops::Snapshot.find_by(key: snapshot_key).update!(taken_at: 50.minutes.ago)
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be true
      end

      it 'enqueues a DriftCheckJob for the probed API, without any network call' do
        expect { described_class.new(api_url:).refresh! }
          .to have_enqueued_job(DriftCheckJob).with(base_url: api_url).on_queue('default')
        expect(APIProxy).not_to have_received(:call)
      end
    end
  end
end
