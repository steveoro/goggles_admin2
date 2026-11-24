# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Target
  #
  # The MySQL database a guided restore replaces: the 'primary' entry of config/database.yml for the running
  # environment, with the hard guards of wizard step 0 and the client command lines.
  #
  # Guards: the environment is 'development'; the host is the local socket, 'localhost', '127.0.0.1' or '::1'; the
  # database name is a plain identifier, is not a production name ('goggles', or the production entry's name) and
  # equals the development entry's name. The production config is never used for anything else.
  #
  # Commands: the password never goes on a command line (MYSQL_PWD in #process_env only; see LocalDb::Cli);
  # the connection options are the ones the app itself uses (host, port, socket, user: with host 'localhost' the
  # client connects through the configured socket, like mysql2), plus --skip-ssl as goggles_db's db:dump / db:rebuild.
  #
  class Target
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
    PRODUCTION_NAMES = %w[goggles].freeze
    NAME_FORMAT = /\A[A-Za-z0-9_$]+\z/

    Check = Data.define(:key, :ok, :detail) do
      def ok? = ok
    end

    attr_reader :env, :config

    def self.current
      new
    end

    # == Params
    # - env: environment name (default Rails.env); config: primary DB settings Hash (default: config/database.yml);
    # - development_database / production_names: overrides of the reference names (specs).
    def initialize(env: Rails.env, config: nil, development_database: :default, production_names: :default)
      @env = env.to_s
      @config = (config || LocalDb::Cli.primary_config).to_h.stringify_keys
      @development_database = development_database == :default ? self.class.database_for('development') : development_database
      @production_names = production_names == :default ? default_production_names : Array(production_names)
    end

    def database = config['database'].to_s
    def host = config['host'].to_s
    def socket = config['socket'].to_s
    def port = config['port'].to_s
    def username = config['username'].to_s
    def development_database = @development_database.to_s

    # The step 0 guards, in order (Array of Check).
    def checks
      [
        Check.new(key: :environment, ok: env == 'development', detail: env),
        Check.new(key: :host, ok: local_host?, detail: host.presence || socket.presence || '-'),
        Check.new(key: :database_name, ok: name_ok?, detail: database.presence || '-')
      ]
    end

    def ok?
      checks.all?(&:ok?)
    end

    # (No host: the client's default local socket.)
    def local_host?
      host.blank? || LOCAL_HOSTS.include?(host.downcase)
    end

    def name_ok?
      database.match?(NAME_FORMAT) && @production_names.exclude?(database) && database == development_database
    end

    # Client argv (Strings, no password): +program+ ('mariadb', 'mariadb-dump'), connection options, then +extra+.
    def client_argv(program, *extra)
      args = [program.to_s]
      args << "--host=#{host}" if host.present?
      args << "--port=#{port}" if port.present?
      args << "--socket=#{socket}" if socket.present?
      args << "--user=#{username}" if username.present?
      args << '--skip-ssl'
      args + extra.flatten.map(&:to_s)
    end

    # Child process environment: the password (MYSQL_PWD) when set.
    def process_env
      LocalDb::Cli.new(config).env
    end

    # Database name of the 'primary' entry of +env_name+ (nil when missing).
    def self.database_for(env_name)
      ActiveRecord::Base.configurations.configs_for(env_name: env_name.to_s, name: 'primary')&.database
    end

    private

    def default_production_names
      (PRODUCTION_NAMES + [self.class.database_for('production')]).compact_blank.uniq
    end
  end
end
