# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'ops rake tasks' do # rubocop:disable RSpec/DescribeClass
  # Migrating a temporary DB swaps the ActiveRecord::Base pool (see OpsDbHelpers): no MySQL rows here.
  self.use_transactional_tests = false

  let(:tmp_dir) { Dir.mktmpdir('ops-rake') }
  let(:db_path) { Pathname.new(use_temp_ops_db(tmp_dir).database) }
  let(:pid_file) { File.join(tmp_dir, 'server.pid') }

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('ops:prepare')
    db_path
    Ops::Database.backup_dir = File.join(tmp_dir, 'dump')
    Ops::Database.server_pid_file = pid_file
  end

  after(:each) do
    Ops::Database.backup_dir = nil
    Ops::Database.server_pid_file = nil
    Ops::Database.reset_state!
    ENV.delete('confirm')
    FileUtils.rm_rf(tmp_dir)
  end

  def invoke_task(name)
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  end

  describe 'ops:prepare' do
    it 'creates the DB from nothing and is idempotent' do
      expect { invoke_task('ops:prepare') }.to output(/'ops' DB migrated\.\n- 'ops' DB state: ready/).to_stdout
      expect(db_path).to exist
      expect { invoke_task('ops:prepare') }.to output(/'ops' DB already prepared\.\n- 'ops' DB state: ready/).to_stdout
      expect(Ops::Database.state).to eq(:ready)
    end

    it 'skips when the ops entry is missing' do
      allow(Ops::Database).to receive(:db_config).and_return(nil)
      expect { invoke_task('ops:prepare') }.to output(/not configured for 'test': skipped/).to_stdout
    end
  end

  describe 'ops:status' do
    it 'reports the state & the row counts' do
      Ops::Database.prepare!
      expect { invoke_task('ops:status') }.to output(/State\.+: ready.*Migrations\.+: current \d+, pending 0.*settings\.+: 1/m).to_stdout
    end
  end

  describe 'ops:backup' do
    it 'writes a labelled backup' do
      Ops::Database.prepare!
      expect { invoke_task('ops:backup') }.to output(/'ops' DB backup: /).to_stdout
      expect(Dir.glob(File.join(tmp_dir, 'dump', 'ops-test-manual-*.sqlite3')).size).to eq(1)
    end
  end

  describe 'ops:reset' do
    before(:each) { Ops::Database.prepare! }

    it 'refuses without the right confirm' do
      ENV['confirm'] = 'production'
      expect { invoke_task('ops:reset') }.to raise_error(SystemExit).and output(/pass confirm=test/).to_stderr
      expect(db_path).to exist
    end

    it 'refuses while the server pid file points to a live process' do
      ENV['confirm'] = 'test'
      File.write(pid_file, Process.pid.to_s)
      expect { invoke_task('ops:reset') }.to raise_error(SystemExit).and output(/server is running/).to_stderr
      expect(Dir.glob(File.join(tmp_dir, 'dump', '*'))).to be_empty
    end

    it 'backs up, deletes & recreates the DB when confirmed' do
      ENV['confirm'] = 'test'
      Ops::Database.with_isolated_connection { |conn| conn.execute("INSERT INTO events (occurred_at, kind, created_at) VALUES ('2026-11-01', 'spec', '2026-11-01')") }
      expect { invoke_task('ops:reset') }.to output(/pre_reset.*recreated, state: ready/m).to_stdout
      Ops::Database.with_isolated_connection { |conn| expect(conn.select_value('SELECT COUNT(*) FROM events')).to eq(0) }
      expect(Dir.glob(File.join(tmp_dir, 'dump', 'ops-test-pre_reset-*.sqlite3')).size).to eq(1)
    end
  end

  describe 'ops:rebuild' do
    # (the app registers its own rebuilders at boot, e.g. :outbox, which would scan the real crawler/data: keep them
    # out of these examples, the ops DB being a temporary one outside the transactional fixtures)
    around(:each) do |example|
      saved = Ops::Rebuilders.all
      saved.each_key { |name| Ops::Rebuilders.unregister(name) }
      example.run
    ensure
      saved&.each { |name, callable| Ops::Rebuilders.register(name, callable) }
    end

    it 'has nothing to rebuild yet' do
      Ops::Database.prepare!
      expect { invoke_task('ops:rebuild') }.to output("Nothing to rebuild yet.\n").to_stdout
    end

    it 'runs the registered rebuilders' do
      Ops::Database.prepare!
      Ops::Rebuilders.register(:spec_rebuilder) { :rebuilt }
      expect { invoke_task('ops:rebuild') }.to output(/spec_rebuilder: :rebuilt/).to_stdout
    ensure
      Ops::Rebuilders.unregister(:spec_rebuilder)
    end
  end
end
