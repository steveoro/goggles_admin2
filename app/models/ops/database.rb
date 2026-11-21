# frozen_string_literal: true

module Ops
  #
  # = Ops::Database
  #
  # Lifecycle of the local SQLite ops DB (entry 'ops:' of config/database.yml).
  #
  # The entry carries <tt>database_tasks: false</tt> & <tt>schema_dump: false</tt>, so that no Rails DB
  # task (db:prepare, db:migrate, db:schema:dump, maintain_test_schema!, ...) ever sees it: the DB is
  # created & migrated only by #prepare! (rake 'ops:prepare', also invoked by 'solid:prepare', and the
  # test suite boot). Migrations are hand-written in db/ops_migrate/.
  #
  # #prepare! swaps the ActiveRecord::Base connection pool while migrating: never call it inside the server.
  #
  class Database
    STATES = %i[not_configured missing needs_migration ready].freeze
    CONFIG_NAME = 'ops'
    # Events older than this are deleted by #prepare!
    EVENT_RETENTION = 180.days
    # Backup files kept (per environment) by #backup!
    BACKUPS_KEPT = 10
    # A :ready state is re-verified after this delay (cheap file check on every call anyway).
    READY_RECHECK_AFTER = 60.seconds
    ISOLATED_OWNER = 'Ops::Database::Isolated'

    # Folder for the backup files (db/dump is gitignored & mounted as a volume in Docker).
    class_attribute :backup_dir, default: nil
    # PID file of the Rails server (checked by 'ops:reset').
    class_attribute :server_pid_file, default: nil

    # backup!, backups, delete_files!, server_running?
    extend Files

    class << self
      # Returns the hidden 'ops' DatabaseConfig for the current environment, or nil.
      def db_config
        ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: CONFIG_NAME, include_hidden: true)
      end

      def configured?
        db_config.present?
      end

      # Absolute Pathname of the SQLite file (nil when not configured).
      def database_path(config = db_config)
        return unless config

        Pathname.new(config.database.to_s).expand_path(Rails.root)
      end

      # Returns one of STATES. Never creates the DB file.
      def state
        return :not_configured unless configured?
        return :missing unless File.exist?(database_path)
        return :ready if ready_cached?

        if needs_migration?
          :needs_migration
        else
          @ready_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          :ready
        end
      rescue StandardError => e
        Rails.logger.warn("[Ops::Database] state check failed: #{e.class}: #{e.message}")
        :needs_migration
      end

      # Forgets the cached :ready state.
      def reset_state!
        @ready_checked_at = nil
      end

      # True when the DB file exists and has pending migrations (false when missing or not configured).
      def needs_migration?(config = db_config)
        return false unless config && File.exist?(database_path(config))

        with_isolated_connection(config) { |conn| conn.pool.migration_context.needs_migration? }
      end

      # Creates the DB file when missing, migrates it when needed (after a backup when it already holds
      # applied migrations), seeds the 'db_epoch' setting and prunes the events older than EVENT_RETENTION.
      # Returns a Hash: { state:, migrated:, backup:, pruned: }.
      # Only for rake tasks & the test suite boot (see the class notes).
      def prepare!(verbose: false)
        config = db_config
        return { state: :not_configured, migrated: false, backup: nil, pruned: 0 } unless config

        path = database_path(config)
        FileUtils.mkdir_p(path.dirname)
        backup = nil
        migrated = !File.exist?(path) || needs_migration?(config)
        if migrated
          backup = backup!(label: 'pre_migrate') if applied_migrations?(config)
          migrate!(config, verbose:)
        end
        pruned = with_isolated_connection(config) do |conn|
          seed_db_epoch(conn)
          prune_events(conn)
        end
        reset_state!
        { state: state, migrated:, backup:, pruned: }
      end

      # Yields a connection on a private ConnectionHandler (does not touch ActiveRecord::Base nor the
      # Ops::ApplicationRecord pools), disconnecting it afterwards.
      def with_isolated_connection(config = db_config, &)
        handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
        pool = handler.establish_connection(config, owner_name: ISOLATED_OWNER)
        pool.with_connection(&)
      ensure
        handler&.clear_all_connections!
      end

      private

      def ready_cached?
        @ready_checked_at.present? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - @ready_checked_at < READY_RECHECK_AFTER
      end

      def applied_migrations?(config)
        return false unless File.exist?(database_path(config)) && File.size(database_path(config)).positive?

        with_isolated_connection(config) { |conn| conn.pool.migration_context.current_version.positive? }
      end

      # Runs the pending db/ops_migrate migrations: Rails migrations always run on the
      # ActiveRecord::Base connection, hence the temporary pool swap.
      def migrate!(config, verbose:)
        verbose_was = ActiveRecord::Migration.verbose
        ActiveRecord::Migration.verbose = verbose
        ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
          conn.pool.migration_context.migrate
        end
      ensure
        ActiveRecord::Migration.verbose = verbose_was
      end

      # (Reads first: on an already prepared DB the suite boot & 'ops:prepare' take no write lock.)
      def seed_db_epoch(conn)
        key_col = conn.quote_column_name('key')
        key = conn.quote(Ops::Setting::DB_EPOCH_KEY)
        return if conn.select_value("SELECT 1 FROM settings WHERE #{key_col} = #{key}")

        now = conn.quote(Time.now.utc)
        conn.execute(
          "INSERT OR IGNORE INTO settings (#{key_col}, #{conn.quote_column_name('value')}, created_at, updated_at) " \
          "VALUES (#{key}, '1', #{now}, #{now})"
        )
      end

      # Returns the number of deleted events.
      def prune_events(conn)
        condition = "occurred_at < #{conn.quote(EVENT_RETENTION.ago.utc)}"
        return 0 unless conn.select_value("SELECT 1 FROM events WHERE #{condition} LIMIT 1")

        conn.delete("DELETE FROM events WHERE #{condition}")
      end
    end
  end
end
