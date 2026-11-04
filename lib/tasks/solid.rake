# frozen_string_literal: true

#
# = Solid Queue / Solid Cable local DB helper tasks
#
#   - for Goggles framework vers.: 7+
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :solid do
  # Local SQLite DB names (see config/database.yml) => sentinel table checked for existence
  SOLID_DBS = { 'queue' => 'solid_queue_jobs', 'cable' => 'solid_cable_messages' }.freeze unless defined? SOLID_DBS

  desc <<~DESC
    Idempotent setup for the local SQLite DBs used by Solid Queue & Solid Cable.

    Loads db/queue_schema.rb and db/cable_schema.rb only when their tables are missing;
    never touches the primary (MySQL) database. Safe to run at every boot.

    Usage:
      > bin/rails solid:prepare

  DESC
  task prepare: :environment do
    SOLID_DBS.each do |db_name, sentinel_table|
      db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: db_name)
      if db_config.nil?
        puts("- '#{db_name}' DB not configured for '#{Rails.env}': skipped.")
        next
      end

      ActiveRecord::Tasks::DatabaseTasks.create(db_config)
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_pool_for_each(env: Rails.env, name: db_name) do |pool|
        if pool.with_connection { |conn| conn.table_exists?(sentinel_table) }
          puts("- '#{db_name}' DB already prepared.")
        else
          ActiveRecord::Tasks::DatabaseTasks.load_schema(db_config)
          puts("- '#{db_name}' DB schema loaded.")
        end
      end
    end
  end
end
