# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::Database do
  # Migrating a temporary DB swaps the ActiveRecord::Base pool (see OpsDbHelpers): no MySQL rows here.
  self.use_transactional_tests = false

  let(:tmp_dir) { Dir.mktmpdir('ops-database') }
  let(:config) { use_temp_ops_db(tmp_dir) }
  let(:db_path) { Pathname.new(config.database) }

  before(:each) { described_class.backup_dir = File.join(tmp_dir, 'dump') }

  after(:each) do
    described_class.backup_dir = nil
    described_class.reset_state!
    FileUtils.rm_rf(tmp_dir)
  end

  describe '.configured? / .db_config' do
    it 'finds the hidden ops entry of the test environment' do
      expect(described_class).to be_configured
      expect(described_class.db_config.database).to eq('db/ops/test.sqlite3')
      expect(described_class.db_config.database_tasks?).to be false
    end

    it 'keeps the ops entry hidden from the Rails DB tasks' do
      expect(ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).map(&:name)).not_to include('ops')
    end
  end

  describe '.state' do
    it 'is :not_configured without an ops entry' do
      allow(described_class).to receive(:db_config).and_return(nil)
      expect(described_class.state).to eq(:not_configured)
      expect(Ops.state).to eq(:not_configured)
      expect(Ops).not_to be_available
    end

    it 'is :missing without the DB file, and never creates it' do
      config
      expect(described_class.state).to eq(:missing)
      expect(Ops).not_to be_available
      expect(db_path).not_to exist
      expect(db_path.dirname).not_to exist
    end

    it 'is :needs_migration on an empty DB file' do
      FileUtils.mkdir_p(db_path.dirname)
      described_class.with_isolated_connection(config) { |conn| conn.execute('SELECT 1') }
      expect(db_path).to exist
      expect(described_class.state).to eq(:needs_migration)
    end

    it 'is :ready once prepared' do
      config
      described_class.prepare!
      expect(described_class.state).to eq(:ready)
      expect(Ops).to be_available
    end
  end

  describe '.prepare!' do
    before(:each) { config }

    it 'creates the DB from nothing, migrates it & seeds the db_epoch' do
      result = described_class.prepare!
      expect(result).to include(state: :ready, migrated: true, backup: nil, pruned: 0)
      expect(db_path).to exist
      described_class.with_isolated_connection(config) do |conn|
        expect(%w[events settings snapshots].select { |table| conn.table_exists?(table) }).to eq(%w[events settings snapshots])
        expect(conn.select_value("SELECT value FROM settings WHERE key = 'db_epoch'").to_s).to eq('1')
      end
    end

    it 'is idempotent' do
      described_class.prepare!
      result = described_class.prepare!
      expect(result).to include(state: :ready, migrated: false, backup: nil)
      described_class.with_isolated_connection(config) do |conn|
        expect(conn.select_value('SELECT COUNT(*) FROM settings')).to eq(1)
      end
    end

    it 'backs up a DB holding applied migrations before migrating it' do
      described_class.prepare!
      described_class.with_isolated_connection(config) do |conn|
        conn.execute("DELETE FROM schema_migrations WHERE version = '20261121100003'")
        conn.execute('DROP TABLE snapshots')
      end
      described_class.reset_state!
      expect(described_class.state).to eq(:needs_migration)

      result = described_class.prepare!
      expect(result[:migrated]).to be true
      expect(result[:backup]).to be_a(Pathname).and(exist)
      expect(result[:backup].basename.to_s).to start_with("ops-#{Rails.env}-pre_migrate-")
      expect(described_class.state).to eq(:ready)
    end

    it 'prunes the events older than the retention period' do
      described_class.prepare!
      described_class.with_isolated_connection(config) do |conn|
        [200.days.ago, 10.days.ago].each do |time|
          conn.execute("INSERT INTO events (occurred_at, kind, created_at) VALUES (#{conn.quote(time.utc)}, 'spec', #{conn.quote(time.utc)})")
        end
      end
      expect(described_class.prepare![:pruned]).to eq(1)
      described_class.with_isolated_connection(config) do |conn|
        expect(conn.select_value('SELECT COUNT(*) FROM events')).to eq(1)
      end
    end

    it 'does nothing when not configured' do
      allow(described_class).to receive(:db_config).and_return(nil)
      expect(described_class.prepare!).to include(state: :not_configured, migrated: false)
    end
  end

  describe '.backup!' do
    before(:each) do
      config
      described_class.prepare!
    end

    it 'writes a usable copy of the DB under the backup folder' do
      dest = described_class.backup!(label: 'spec run')
      expect(dest.dirname.to_s).to eq(File.join(tmp_dir, 'dump'))
      expect(dest.basename.to_s).to match(/\Aops-test-spec_run-\d{8}-\d{9}(-\h{4})?\.sqlite3\z/)
      copy = temp_ops_db_config(dest)
      described_class.with_isolated_connection(copy) do |conn|
        expect(conn.table_exists?('events')).to be true
      end
    end

    it "keeps only the newest #{described_class::BACKUPS_KEPT} backups" do
      dests = Array.new(described_class::BACKUPS_KEPT + 2) { described_class.backup! }
      kept = described_class.backups(Pathname.new(File.join(tmp_dir, 'dump')))
      expect(kept.size).to eq(described_class::BACKUPS_KEPT)
      expect(kept).to include(dests.last.to_s)
      expect(kept).not_to include(dests.first.to_s)
    end

    it 'returns nil when the DB file is missing' do
      described_class.delete_files!
      expect(described_class.backup!).to be_nil
    end
  end

  describe '.server_running?' do
    let(:pid_file) { File.join(tmp_dir, 'server.pid') }

    before(:each) { described_class.server_pid_file = pid_file }
    after(:each) { described_class.server_pid_file = nil }

    it 'is false without a pid file' do
      expect(described_class.server_running?).to be false
    end

    it 'is true when the pid file points to a live process' do
      File.write(pid_file, Process.pid.to_s)
      expect(described_class.server_running?).to be true
    end

    it 'is false for a stale pid file' do
      allow(Process).to receive(:kill).with(0, 999_999).and_raise(Errno::ESRCH)
      File.write(pid_file, '999999')
      expect(described_class.server_running?).to be false
    end
  end
end
