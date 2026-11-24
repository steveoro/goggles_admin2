# frozen_string_literal: true

#
# = Local SQLite "ops" DB tasks (see Ops::Database)
#
#   - for Goggles framework vers.: 7+
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :ops do # rubocop:disable Metrics/BlockLength
  desc <<~DESC
    Idempotent setup of the local SQLite ops DB ('ops:' entry of config/database.yml, file db/ops/<env>.sqlite3).

    Creates the DB file when missing, applies the pending db/ops_migrate migrations (after a backup
    under db/dump/ when the DB already holds data), seeds the 'db_epoch' setting, deletes the
    events older than 180 days and the web sessions not used for 30 days. Never touches the
    primary (MySQL) DB.
    Also invoked by 'solid:prepare'.

    Usage:
      > bin/rails ops:prepare

  DESC
  task prepare: :environment do
    result = Ops::Database.prepare!(verbose: ENV['VERBOSE'].present?)
    if result[:state] == :not_configured
      puts("- 'ops' DB not configured for '#{Rails.env}': skipped (add the 'ops:' entry from config/database.example.yml).")
      next
    end

    puts("- 'ops' DB backup: #{result[:backup].relative_path_from(Rails.root)}") if result[:backup]
    puts(result[:migrated] ? "- 'ops' DB migrated." : "- 'ops' DB already prepared.")
    puts("- 'ops' DB: #{result[:pruned]} old event(s) pruned.") if result[:pruned].to_i.positive?
    puts("- 'ops' DB: #{result[:sessions_trimmed]} old web session(s) deleted.") if result[:sessions_trimmed].to_i.positive?
    puts("- 'ops' DB state: #{result[:state]}")
  end

  desc <<~DESC
    Shows the state of the local ops DB: file, migrations, row counts, db_epoch & backups.

    Usage:
      > bin/rails ops:status

  DESC
  task status: :environment do
    state = Ops::Database.state
    puts("State.......: #{state}")
    next if state == :not_configured

    path = Ops::Database.database_path
    puts("File........: #{path.relative_path_from(Rails.root)}#{" (#{File.size(path)} bytes)" if File.exist?(path)}")
    if File.exist?(path)
      Ops::Database.with_isolated_connection do |conn|
        context = conn.pool.migration_context
        puts("Migrations..: current #{context.current_version}, pending #{context.open.pending_migrations.size}")
        # (every ops table: events, settings, snapshots, the Outbox registry, health, pipeline, sessions, ...)
        tables = %w[events settings snapshots] | (conn.tables - %w[schema_migrations ar_internal_metadata]).sort
        width = [12, tables.map(&:size).max.to_i + 1].max
        tables.each do |table|
          count = conn.table_exists?(table) ? conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(table)}") : '-'
          puts("#{table.ljust(width, '.')}: #{count}")
        end
      end
    end
    puts("db_epoch....: #{Ops::Setting.db_epoch}") if state == :ready
    puts("Backups.....: #{Ops::Database.backups.size} (kept: #{Ops::Database::BACKUPS_KEPT})")
  end

  desc <<~DESC
    Copies the local ops DB to db/dump/ops-<env>-<label>-<UTC timestamp>.sqlite3
    (keeps the newest 10 backups of the environment).

    Options: [label=manual]

    Usage:
      > bin/rails ops:backup label=before_cleanup

  DESC
  task backup: :environment do
    dest = Ops::Database.backup!(label: ENV.fetch('label', 'manual'))
    puts(dest ? "- 'ops' DB backup: #{dest.relative_path_from(Rails.root)}" : "- 'ops' DB missing or not configured: nothing to back up.")
  end

  desc <<~DESC
    Deletes & recreates the local ops DB (after a backup). Refused while the Rails server
    (tmp/pids/server.pid) is running.

    Options: confirm=<Rails.env> (required, must match the current environment)

    Usage:
      > bin/rails ops:reset confirm=development

  DESC
  task reset: :environment do
    abort("Refused: pass confirm=#{Rails.env} to reset the '#{Rails.env}' ops DB.") if ENV['confirm'].to_s != Rails.env
    abort('Refused: the Rails server is running (tmp/pids/server.pid); stop it first.') if Ops::Database.server_running?
    abort("Refused: no 'ops' entry for '#{Rails.env}' in config/database.yml.") unless Ops::Database.configured?

    dest = Ops::Database.backup!(label: 'pre_reset')
    puts("- 'ops' DB backup: #{dest.relative_path_from(Rails.root)}") if dest
    Ops::Database.delete_files!
    result = Ops::Database.prepare!(verbose: ENV['VERBOSE'].present?)
    puts("- 'ops' DB recreated, state: #{result[:state]}")
  end

  desc <<~DESC
    Recomputes the ops DB contents derived from other sources, running every callable registered
    with Ops::Rebuilders.register (or just one of them).

    Options: [name=<rebuilder name>]

    Usage:
      > bin/rails ops:rebuild

  DESC
  task rebuild: :environment do
    abort("Refused: the 'ops' DB is #{Ops.state}; run 'bin/rails ops:prepare' first.") unless Ops.available?

    if Ops::Rebuilders.names.empty?
      puts('Nothing to rebuild yet.')
      next
    end

    Ops::Rebuilders.run!(only: ENV['name'].presence).each do |name, result|
      puts("- #{name}: #{result.inspect.truncate(200)}")
    end
  end
end
