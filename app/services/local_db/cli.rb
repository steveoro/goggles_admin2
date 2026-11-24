# frozen_string_literal: true

module LocalDb
  #
  # = LocalDb::Cli
  #
  # Command line of the MariaDB/MySQL client for the local primary (MySQL) DB of the current environment.
  #
  # The password is never put on the command line (where any process listing shows it): it goes in the
  # MYSQL_PWD environment variable of the child process only (#env).
  #
  # == Usage
  #   cli = LocalDb::Cli.new
  #   Open3.capture3(cli.env, *cli.argv, stdin_data: sql)
  #
  class Cli
    CLIENT = 'mariadb'

    attr_reader :config

    # == Params
    # - config: Hash of the DB settings ('database', 'username', 'password', 'host'; String or Symbol keys);
    #   default: the 'primary' entry of config/database.yml for Rails.env.
    def initialize(config = nil)
      @config = (config || self.class.primary_config).to_h.stringify_keys
    end

    # The primary DB settings Hash for the current environment.
    def self.primary_config
      db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: 'primary') ||
                  ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first
      db_config.configuration_hash
    end

    # The client argv (Array of Strings), without the password.
    def argv(extra = [])
      args = [CLIENT]
      args << "--host=#{config['host']}" if config['host'].present?
      args << "--user=#{config['username']}" if config['username'].present?
      args << "--database=#{config['database']}"
      args + Array(extra)
    end

    # Environment for the child process (the password, when set).
    def env
      config['password'].present? ? { 'MYSQL_PWD' => config['password'].to_s } : {}
    end

    def database
      config['database']
    end
  end
end
