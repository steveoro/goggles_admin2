# frozen_string_literal: true

require 'rails_helper'

# mariadb-dump is never started: the argv is checked, and the pipeline runs with `cat` of a hand-made SQL file.
RSpec.describe DbRestore::Snapshot do
  let(:dir) { Pathname.new(Dir.mktmpdir) }
  let(:catalog) { DbRestore::DumpCatalog.new(dirs: [dir.to_s]) }
  let(:run) { create_restore_run(status: 'snapshotting', dump_bytes: 1_000) }
  let(:target) { passing_target }
  let(:sql_file) do
    path = dir.join('local.sql')
    path.write("CREATE DEFINER=`root`@`localhost` VIEW `v` AS select 1;\nINSERT INTO `users` VALUES (1);\n")
    path.to_s
  end
  # DbRestore::Commands with mariadb-dump replaced by `cat <sql_file>` and a fixed free space.
  let(:commands) do
    sql = sql_file
    free = 10_000
    Module.new do
      define_singleton_method(:free_bytes) { |_dir| free }
      define_singleton_method(:dump_to) do |**options|
        DbRestore::Commands.dump_to(**options, dump_argv: ['cat', sql])
      end
    end
  end

  before(:each) do
    File.binwrite(dir.join('production-0430-backup.sql.bz2'), 'x')
    allow(Ops::Database).to receive(:backup!).and_return(dir.join('ops-test-pre_restore.sqlite3'))
  end

  after(:each) do
    FileUtils.rm_rf(dir)
    Ops::Database.reset_state!
  end

  it 'builds the mariadb-dump argv without the password (MYSQL_PWD only in the child env)' do
    snapshot = described_class.new(run:, target:, catalog:, commands:)
    expect(snapshot.dump_argv).to eq(['mariadb-dump', '--host=localhost', '--user=root', '--skip-ssl', '--add-drop-table', '--routines',
                                      '--events', '--triggers', '--single-transaction', 'goggles_development'])
    expect(snapshot.dump_argv.join(' ')).not_to include('secret-pwd')
    expect(target.process_env).to eq('MYSQL_PWD' => 'secret-pwd')
  end

  it 'writes the next development-NNNN-pre-restore dump with the db:dump header and footer, definers stripped, then backs up the ops DB' do
    path = described_class.new(run:, target:, catalog:, commands:).call
    expect(path).to eq(dir.join('development-0431-pre-restore.sql.bz2').to_s)
    sql = IO.popen(['bzip2', '-dc', path], 'rb', &:read)
    expect(sql).to start_with("-- #{dir.join('development-0431-pre-restore.sql')}\r\nSET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";\n" \
                              "SET AUTOCOMMIT = 0;\nSTART TRANSACTION;\n\r\n--\r\n")
    expect(sql).to include('CREATE VIEW `v` AS select 1;')
    expect(sql).not_to include('DEFINER')
    expect(sql).to end_with("\r\n--\r\nCOMMIT;\n")
    expect(Ops::Database).to have_received(:backup!).with(label: 'pre_restore')
    expect(run.reload).to have_attributes(snapshot_path: path, ops_backup_path: dir.join('ops-test-pre_restore.sqlite3').to_s)
    expect(Dir.glob(dir.join('*.partial'))).to be_empty
  end

  it 'refuses without 3 times the dump size of free space' do
    run.update!(dump_bytes: 4_000)
    expect { described_class.new(run:, target:, catalog:, commands:).call }.to raise_error(DbRestore::Refused, /3/)
    expect(Dir.glob(dir.join('development-*'))).to be_empty
  end

  it 'leaves no partial file when the dump command fails' do
    failing = Module.new do
      define_singleton_method(:free_bytes) { |_dir| 10_000 }
      define_singleton_method(:dump_to) do |**options|
        DbRestore::Commands.dump_to(**options, dump_argv: ['sh', '-c', 'echo "Access denied" >&2; exit 2'])
      end
    end
    expect { described_class.new(run:, target:, catalog:, commands: failing).call }.to raise_error(DbRestore::CommandFailed, /Access denied/)
    expect(Dir.glob(dir.join('development-*'))).to be_empty
    expect(run.reload.snapshot_path).to be_nil
  end
end
