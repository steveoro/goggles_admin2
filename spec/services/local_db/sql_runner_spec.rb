# frozen_string_literal: true

require 'rails_helper'

# Never runs SQL for real: Open3.capture3 is stubbed, or the client is replaced by a plain shell command (cat / sh)
# that only echoes the piped script, so the real pipe encoding is exercised without a DB.
RSpec.describe LocalDb::SqlRunner do
  let(:dir) { Pathname.new(Dir.mktmpdir) }
  let(:path) { write_sql_file(dir, 'results.new/misc/0001-x.sql', "UPDATE x SET a=1;\r\n") }
  let(:cli) { LocalDb::Cli.new('database' => 'goggles_test', 'username' => 'someone', 'password' => 'secret-pwd', 'host' => 'localhost') }
  let(:ok_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:ko_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  after(:each) { FileUtils.rm_rf(dir) }

  it 'pipes the file wrapped in a transaction to the client, with the password in MYSQL_PWD only' do
    allow(Open3).to receive(:capture3).and_return(['', '', ok_status])
    result = described_class.call(path:, cli:)

    expect(result).to be_success
    expect(result.duration).to be >= 0
    expect(Open3).to have_received(:capture3) do |env, *argv, stdin_data:, binmode:|
      expect(binmode).to be(true)
      expect(env).to eq('MYSQL_PWD' => 'secret-pwd')
      expect(argv).to eq(%w[mariadb --host=localhost --user=someone --database=goggles_test])
      expect(argv.join(' ')).not_to include('secret-pwd')
      expect(stdin_data).to eq("START TRANSACTION;\nUPDATE x SET a=1;\r\n\nCOMMIT;\n")
    end
  end

  it 'returns a failed result with the client error, never exiting' do
    allow(Open3).to receive(:capture3).and_return(['', 'ERROR 1064 (42000) at line 2', ko_status])
    result = described_class.call(path:, cli:)
    expect(result).not_to be_success
    expect(result).to have_attributes(stderr: 'ERROR 1064 (42000) at line 2', exit_code: 1)
  end

  it 'fails without running the client for a missing file' do
    allow(Open3).to receive(:capture3)
    result = described_class.call(path: dir.join('nope.sql'), cli:)
    expect(result).not_to be_success
    expect(result.stderr).to include('File not found')
    expect(Open3).not_to have_received(:capture3)
  end

  it 'fails when the client cannot be started' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, 'mariadb')
    expect(described_class.call(path:, cli:).stderr).to include('ENOENT')
  end

  # A real child process with Rails' Encoding.default_internal (UTF-8): the script is read in binary, so the pipes must
  # be binary too (a text-mode pipe tries to transcode the bytes and raises Encoding::UndefinedConversionError).
  describe 'with a real child process (no DB: the client is a shell command)' do
    let(:sql) { "UPDATE meetings SET description='Città di Saronno', notes='Società' WHERE id=1;\n" }
    let(:path) { write_sql_file(dir, 'results.new/normalize/0002-x.sql', sql) }
    let(:echo_cli) { Struct.new(:env, :argv).new({}, %w[cat]) }
    let(:failing_cli) { Struct.new(:env, :argv).new({}, ['sh', '-c', "printf 'ERROR 1054 at line 2: Unknown column \\303\\240\\n' >&2; exit 1"]) }

    it 'pipes a UTF-8 script unchanged and returns the output as UTF-8' do
      result = described_class.call(path:, cli: echo_cli)

      expect(result).to be_success
      expect(result.stdout.encoding).to eq(Encoding::UTF_8)
      expect(result.stdout).to be_valid_encoding
      expect(result.stdout).to eq("START TRANSACTION;\n#{sql}\nCOMMIT;\n")
    end

    it 'pipes bytes that are not valid UTF-8 as they are' do
      raw = "UPDATE x SET a='caf\xE9';\n".b
      bad_path = dir.join('results.new/misc/0003-latin1.sql').tap { |file| FileUtils.mkdir_p(file.dirname) }
      File.binwrite(bad_path, raw)
      result = described_class.call(path: bad_path, cli: echo_cli)

      expect(result).to be_success
      expect(result.stdout).to be_valid_encoding
      expect(result.stdout).to include("UPDATE x SET a='caf")
    end

    it 'returns a client error with non-ASCII text as valid UTF-8' do
      result = described_class.call(path:, cli: failing_cli)

      expect(result).not_to be_success
      expect(result.exit_code).to eq(1)
      expect(result.stderr.encoding).to eq(Encoding::UTF_8)
      expect(result.stderr).to eq("ERROR 1054 at line 2: Unknown column à\n")
      expect { result.stderr.to_json }.not_to raise_error
    end
  end

  it 'reads the primary DB settings by default' do
    expect(LocalDb::Cli.new.database).to eq(ActiveRecord::Base.connection_db_config.database)
  end
end
