# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DbRestore::Target do
  def target(config)
    described_class.new(env: 'development', config: { 'database' => 'goggles_development', 'username' => 'root' }.merge(config),
                        development_database: 'goggles_development')
  end

  it 'passes the configured host, port and socket to the clients (as the app connects), never the password' do
    argv = target('host' => 'localhost', 'port' => 3306, 'socket' => '/var/run/mysqld/mysqld.sock', 'password' => 'pwd')
           .client_argv('mariadb', '--database=goggles_development')
    expect(argv).to eq(['mariadb', '--host=localhost', '--port=3306', '--socket=/var/run/mysqld/mysqld.sock', '--user=root',
                        '--skip-ssl', '--database=goggles_development'])
    expect(argv.join(' ')).not_to include('pwd')
  end

  it 'passes a non-default port, so that the commands reach the same server as the app' do
    expect(target('host' => '127.0.0.1', 'port' => 3307).client_argv('mariadb-dump'))
      .to eq(['mariadb-dump', '--host=127.0.0.1', '--port=3307', '--user=root', '--skip-ssl'])
  end

  it 'guards the environment, the host and the database name' do
    expect(target('host' => 'localhost')).to be_ok
    expect(target('host' => 'db.example.org').checks.reject(&:ok?).map(&:key)).to eq([:host])
    expect(described_class.new(env: 'test', config: { 'database' => 'goggles_development' }, development_database: 'goggles_development').checks
             .reject(&:ok?).map(&:key)).to eq([:environment])
  end
end
