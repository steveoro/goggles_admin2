# frozen_string_literal: true

require 'rails_helper'

# Never runs SQL for real: Open3.capture3 is stubbed in every example.
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
    expect(Open3).to have_received(:capture3) do |env, *argv, stdin_data:|
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

  it 'reads the primary DB settings by default' do
    expect(LocalDb::Cli.new.database).to eq(ActiveRecord::Base.connection_db_config.database)
  end
end
