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

    it 'is :warn for a reachable server not checked for over 10 minutes (still :error when unreachable)' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200 })
      Ops::Snapshot.find_by(key: "api.status:#{api_url}").update!(taken_at: 11.minutes.ago)
      expect(described_class.new(api_url:).call.level).to eq(:warn)
      Ops::Snapshot.find_by(key: "api.status:#{api_url}").update!(taken_at: 9.minutes.ago)
      expect(described_class.new(api_url:).call.level).to eq(:ok)

      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => false, 'code' => 503, 'error' => 'refused' })
      Ops::Snapshot.find_by(key: "api.status:#{api_url}").update!(taken_at: 2.hours.ago)
      expect(described_class.new(api_url:).call.level).to eq(:error)
    end

    it 'is :unknown in an API-offline session, whatever the snapshot says, linking to Settings' do
      Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200 })
      result = described_class.new(api_url:, offline: true).call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('shell.status.api.offline'))
      expect(result.action[:path]).to eq('/settings')
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

    let(:pid_path) { described_class.pid_path }
    let(:status_path) { described_class.status_path }

    after(:each) { FileUtils.rm_f([status_path, pid_path]) }
    before(:each) { FileUtils.rm_f([status_path, pid_path]) }

    it_behaves_like 'a probe that never raises'
    it_behaves_like 'a snapshot probe that never touches the network while evaluated'

    def write_status(status, detail: '', timestamp: Time.now.utc, progress: 0, total: 0)
      File.write(status_path, { status:, detail:, timestamp: timestamp.strftime('%Y%m%d-%H%M%S'), progress:, total: }.to_json)
    end

    def running!
      FileUtils.mkdir_p(pid_path.dirname)
      File.write(pid_path, Process.pid.to_s) # (this very process: alive)
    end

    it 'reads its status and PID files from the test paths' do
      expect(status_path.to_s).to end_with('tmp/crawler-status.test.json')
      expect(pid_path.to_s).to end_with('tmp/pids/crawler.test.pid')
    end

    it 'is :error ("not running", with the Start crawler button) when the PID process is gone or the last check found nothing' do
      FileUtils.mkdir_p(pid_path.dirname)
      File.write(pid_path, '999999999')
      result = described_class.new.call
      expect(result.level).to eq(:error)
      expect(result.detail).to eq(I18n.t('shell.status.crawler.off'))
      expect(result.action).to include(path: '/pull/start_crawler', http_method: :post)
      expect(result).to be_post_action

      FileUtils.rm_f(pid_path)
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => false })
      expect(described_class.new.call.level).to eq(:error)
    end

    it 'is :unknown without a PID process nor a recent check' do
      result = described_class.new.call
      expect(result.level).to eq(:unknown)
      expect(result.action[:path]).to eq('/pull/start_crawler')
    end

    it 'reads the status file while running: idle :ok, busy :ok with its progress, failed or stuck :warn' do
      running!
      write_status('OK, idle')
      expect(described_class.new.call.level).to eq(:ok)

      write_status('OK, processing', progress: 2, total: 5)
      result = described_class.new.call
      expect(result.level).to eq(:ok)
      expect(result.detail).to eq(I18n.t('shell.status.crawler.busy_progress', status: 'OK, processing', progress: 2, total: 5))

      write_status('OK, running', timestamp: 40.minutes.ago.utc)
      expect(described_class.new.call.level).to eq(:warn)

      write_status('ERROR', detail: 'Timeout')
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.detail).to include('Timeout')
    end

    it 'trusts a recent HTTP check for a crawler started by hand (no PID file)' do
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => true, 'status' => 'OK, idle' })
      expect(described_class.new.call.level).to eq(:ok)
      Ops::Snapshot.find_by(key: 'system_status.crawler').update!(taken_at: 1.hour.ago)
      expect(described_class.new.call.level).to eq(:unknown)
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

      def live(kind, queues = nil, beat: 30.seconds.ago)
        SystemStatus::QueueProbe::LiveProcess.new(kind:, queues: Array(queues), last_heartbeat_at: beat)
      end

      it 'is :ok with a supervisor and a worker for each queue of config/queue.yml' do
        workers = described_class.configured_queues.map { |queue| live('Worker', queue) }
        allow(described_class).to receive(:live_processes)
          .and_return([live('Supervisor(fork)'), live('Dispatcher'), *workers])
        result = described_class.new.call
        expect(result.level).to eq(:ok)
        expect(result.detail).to include((2 + workers.size).to_s)
        expect(described_class).to have_received(:live_processes).with(since: be_within(5.seconds).of(5.minutes.ago))
      end

      it 'is :warn when a configured queue has no live worker' do
        allow(described_class).to receive(:live_processes).and_return([live('Supervisor(fork)'), live('Worker', 'default')])
        result = described_class.new.call
        expect(result.level).to eq(:warn)
        expect(result.detail).to include('background')
      end

      it 'is :error without a live supervisor, telling to run bin/jobs when outside Puma' do
        allow(described_class).to receive_messages(live_processes: [live('Worker', 'default')], outside_puma?: false)
        result = described_class.new.call
        expect(result.level).to eq(:error)
        expect(result.detail).to eq(I18n.t('shell.status.queue.dead'))

        allow(described_class).to receive(:outside_puma?).and_return(true)
        expect(described_class.new.call.detail).to eq(I18n.t('shell.status.queue.dead_outside_puma'))
      end

      it 'reads the configured queues from config/queue.yml' do
        expect(described_class.configured_queues).to include('default', 'background', 'maintenance')
      end

      it 'is :unknown when the queue DB/tables are missing (no exception)' do
        allow(described_class).to receive(:live_processes).and_raise(ActiveRecord::StatementInvalid, 'no such table')
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

    it 'is :error when the last check failed, offering "Check now"' do
      store.update { |state| state.merge('last_checked' => Time.current.iso8601, 'last_error' => 'FetchError: 503') }
      result = described_class.new.call
      expect(result.level).to eq(:error)
      expect(result.detail).to include('503')
      expect(result.action).to include(path: '/federnuoto_watch/check', http_method: :post)
    end

    it 'is :warn when the last check is older than 75 minutes (the hourly job is not running)' do
      store.update { |state| state.merge('last_checked' => 80.minutes.ago.iso8601) }
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.action[:path]).to eq('/federnuoto_watch/check')
    end
  end

  describe SystemStatus::CableProbe do
    let(:probe_class) { described_class }

    it_behaves_like 'a probe that never raises'

    it 'has key :cable, inline' do
      expect(described_class.key).to eq(:cable)
      expect(described_class.mode).to eq(:inline)
    end

    it 'is :warn with the in-process test adapter (no broadcast across processes)' do
      result = described_class.new.call
      expect(result.level).to eq(:warn)
      expect(result.detail).to eq(I18n.t('shell.status.cable.other_adapter', adapter: 'test'))
    end

    context 'with the solid_cable adapter' do
      before(:each) { allow(ActionCable.server.config).to receive(:cable).and_return({ 'adapter' => 'solid_cable' }) }

      it 'is :warn without a cable database in config/database.yml (the test environment has none)' do
        expect(described_class.new.call.detail).to eq(I18n.t('shell.status.cable.not_configured'))
      end

      it 'is :warn when its SQLite file is missing, without creating it, and :ok once prepared' do
        config = ActiveRecord::DatabaseConfigurations::HashConfig.new('test', 'cable', { adapter: 'sqlite3', database: 'tmp/no-such-cable.sqlite3' })
        allow(ActiveRecord::Base.configurations).to receive(:configs_for).and_call_original
        allow(ActiveRecord::Base.configurations).to receive(:configs_for).with(env_name: 'test', name: 'cable').and_return(config)
        expect(described_class.new.call.detail).to eq(I18n.t('shell.status.cable.not_prepared'))
        expect(Rails.root.join('tmp/no-such-cable.sqlite3')).not_to exist

        allow(Rails.root).to receive(:join).and_call_original
        allow(Rails.root).to receive(:join).with('tmp/no-such-cable.sqlite3').and_return(instance_double(Pathname, exist?: true))
        allow(described_class).to receive(:messages_table?).and_return(true)
        expect(described_class.new.call.level).to eq(:ok)
      end
    end
  end

  describe SystemStatus::OpsDbProbe do
    let(:probe_class) { described_class }

    it_behaves_like 'a probe that never raises'

    it 'is :ok when the ops DB is ready, :error with the ops:prepare hint otherwise' do
      expect(described_class.key).to eq(:ops_db)
      expect(described_class.new.call.level).to eq(:ok)
      allow(Ops::Database).to receive(:state).and_return(:needs_migration)
      result = described_class.new.call
      expect(result.level).to eq(:error)
      expect(result.detail).to include(I18n.t('ops.setup_notice.states.needs_migration'), 'ops:prepare')
    end
  end

  describe SystemStatus::DbSyncProbe do
    include ActiveSupport::Testing::TimeHelpers

    let(:probe_class) { described_class }

    def fingerprint(*traits, **attributes)
      FactoryBot.create(:ops_db_fingerprint, *traits, api_base_url: api_url, **attributes)
    end

    it_behaves_like 'a probe that never raises'
    it_behaves_like 'a snapshot probe that never touches the network while evaluated'

    it 'has key :db_sync in snapshot mode (it enqueues the check), labelled "DB sync"' do
      expect(described_class.key).to eq(:db_sync)
      expect(described_class.mode).to eq(:snapshot)
      expect(I18n.t(described_class.label_key, locale: :en)).to eq('DB sync')
    end

    it 'is :unknown ("not checked yet") without a stored check, linking to /db_sync' do
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:unknown)
      expect(result.detail).to eq(I18n.t('db_sync.pill.never'))
      expect(result.action[:path]).to eq('/db_sync')
    end

    it 'maps the last stored verdict of the probed API: green :ok, amber :warn, red :error, unknown :unknown' do
      fingerprint(api_base_url: 'http://other-api:8081', verdict: 'red')
      { nil => :ok, amber: :warn, red: :error, unknown: :unknown }.each do |trait, level|
        row = trait ? fingerprint(trait) : fingerprint
        result = described_class.new(api_url:).call
        expect(result.level).to eq(level), trait.inspect
        expect(result.checked_at).to be_within(1.second).of(row.taken_at)
        expect(result.detail).to include('laps') if trait == :red # (the reasons, translated)
      end
    end

    it 'reads a green check older than 2 hours as :warn (stale)' do
      fingerprint(taken_at: 3.hours.ago)
      result = described_class.new(api_url:).call
      expect(result.level).to eq(:warn)
      expect(result.detail).to include(I18n.t('db_sync.verdicts.amber'))
    end

    it 'is :unknown with the ops DB not ready' do
      allow(Ops).to receive(:available?).and_return(false)
      expect(described_class.new(api_url:).call.detail).to eq(I18n.t('db_sync.pill.ops_unavailable'))
    end

    describe '#refresh_due? and #refresh!' do
      it 'is due only without a check of the job (not of a gate) or past 45 minutes, whatever the shorter max age' do
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be true
        fingerprint(trigger: 'gate', mode: 'light')
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be true # (a gate's own light check)
        fingerprint(taken_at: 30.minutes.ago)
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be false
        Ops::DbFingerprint.job_checks.find_each { |row| row.update!(taken_at: 50.minutes.ago) }
        expect(described_class.new(api_url:).refresh_due?(1.minute)).to be true
      end

      it 'enqueues a DriftCheckJob for the probed API, without any network call' do
        expect { described_class.new(api_url:).refresh! }
          .to have_enqueued_job(DriftCheckJob).with(trigger: 'schedule', base_url: api_url).on_queue('default')
        expect(APIProxy).not_to have_received(:call)
      end
    end
  end
end
