# frozen_string_literal: true

require 'rails_helper'

# The MySQL client is never started: DbRestore::Commands is replaced by a recording fake, or run with harmless
# commands (bunzip2 + cat).
RSpec.describe DbRestore::Loader do
  let(:fixture) { Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2').to_s }
  let(:run) { create_restore_run(status: 'loading', dump_bytes: File.size(fixture)) }
  let(:target) { passing_target }

  # Records the calls; load_stream yields the given progress values.
  let(:commands) do
    Class.new do
      attr_reader :captures, :streams
      attr_accessor :version, :fail_with

      def initialize
        @captures = []
        @streams = []
        @version = 'mariadb from 11.8.3-MariaDB, client 15.2 for debian-linux-gnu (x86_64)'
      end

      def capture!(env, argv) = (@captures << { env:, argv: }) && ''
      def output(_argv) = version

      def load_stream(**options)
        @streams << options
        yield(400)
        raise fail_with if fail_with

        yield(File.size(options[:input_path]))
        ''
      end
    end.new
  end

  after(:each) { Ops::Database.reset_state! }

  it 'drops and recreates the database, then streams the dump into the client: argv without the password' do
    described_class.new(run:, target:, commands:, progress_every: nil).call
    drop = commands.captures.sole
    expect(drop[:argv]).to eq(['mariadb', '--host=localhost', '--user=root', '--skip-ssl',
                               '--execute=DROP DATABASE IF EXISTS `goggles_development`; CREATE DATABASE `goggles_development`;'])
    expect(drop[:env]).to eq('MYSQL_PWD' => 'secret-pwd')
    stream = commands.streams.sole
    expect(stream).to include(decompress_argv: %w[bunzip2 -c], input_path: fixture, env: { 'MYSQL_PWD' => 'secret-pwd' },
                              client_argv: ['mariadb', '--host=localhost', '--user=root', '--skip-ssl', '--database=goggles_development'],
                              filter_sandbox: false)
    expect([*drop[:argv], *stream[:client_argv]].join(' ')).not_to include('secret-pwd')
    expect(run.reload.progress_bytes).to eq(File.size(fixture))
    expect(run.log).to include(I18n.t('db_restore.steps.drop_create'), I18n.t('db_restore.steps.load'))
  end

  it 'reports the progress (compressed bytes) through the heartbeat while loading' do
    loader = described_class.new(run:, target:, commands:, progress_every: 0.01)
    allow(commands).to receive(:load_stream).and_wrap_original do |original, **options, &block|
      original.call(**options) do |bytes|
        block.call(bytes)
        sleep(0.05) if bytes == 400
      end
    end
    allow(run).to receive(:heartbeat!).and_call_original
    loader.call
    expect(run).to have_received(:heartbeat!).with(400).at_least(:once)
  end

  it 'drops the sandbox line for an old client' do
    commands.version = 'mariadb  Ver 15.1 Distrib 10.3.39-MariaDB, for debian-linux-gnu (x86_64)'
    described_class.new(run:, target:, commands:, progress_every: nil).call
    expect(commands.streams.sole[:filter_sandbox]).to be(true)
  end

  it 'raises when the load fails (the restorer marks the run interrupted)' do
    commands.fail_with = DbRestore::CommandFailed.new('mariadb exited with status 1: ERROR 1064')
    expect { described_class.new(run:, target:, commands:, progress_every: nil).call }.to raise_error(DbRestore::CommandFailed, /1064/)
  end

  it 'refuses a missing dump and a target failing the guards before running anything' do
    expect { described_class.new(run:, target:, commands:).call('/nope.sql.bz2') }.to raise_error(DbRestore::Refused)
    bad = DbRestore::Target.new(env: 'development', config: { 'database' => 'goggles' }, development_database: 'goggles')
    expect { described_class.new(run:, target: bad, commands:).call }.to raise_error(DbRestore::Refused)
    expect(commands.captures).to be_empty
  end

  it 'knows which client versions understand the sandbox line' do
    expect(described_class.sandbox_supported?('mariadb from 11.8.3-MariaDB, client 15.2')).to be(true)
    expect(described_class.sandbox_supported?('Distrib 10.11.8-MariaDB')).to be(true)
    expect(described_class.sandbox_supported?('Distrib 10.11.7-MariaDB')).to be(false)
    expect(described_class.sandbox_supported?('mysql  Ver 8.0.36')).to be(false)
  end

  describe DbRestore::Commands do
    it 'streams the decompressed dump into the client command, with or without the sandbox line' do
      fed = []
      kept = described_class.load_stream(env: {}, decompress_argv: %w[bunzip2 -c], client_argv: %w[cat], input_path: fixture) { |bytes| fed << bytes }
      expect(kept).to start_with("-- /app/db/dump/production.sql\r\n")
      expect(kept).to include('enable the sandbox mode')
      expect(fed.last).to eq(File.size(fixture))
      filtered = described_class.load_stream(env: {}, decompress_argv: %w[bunzip2 -c], client_argv: %w[cat], input_path: fixture,
                                             filter_sandbox: true)
      expect(filtered).not_to include('enable the sandbox mode')
      expect(filtered).to include('-- MariaDB dump 10.19')
    end

    it 'raises with the error output when the client fails' do
      expect do
        described_class.load_stream(env: {}, decompress_argv: %w[bunzip2 -c], client_argv: ['sh', '-c', 'echo boom >&2; exit 3'], input_path: fixture)
      end.to raise_error(DbRestore::CommandFailed, /status 3: boom/)
    end

    it 'raises for a failing command' do
      expect { described_class.capture!({}, ['sh', '-c', 'echo nope >&2; exit 2']) }.to raise_error(DbRestore::CommandFailed, /nope/)
    end
  end
end
