# frozen_string_literal: true

# Helpers for specs working on a throw-away ops DB (see Ops::Database).
#
# Migrating swaps the ActiveRecord::Base connection pool, so the example groups that call
# Ops::Database.prepare! on a temporary DB must disable the transactional fixtures
# (<tt>self.use_transactional_tests = false</tt>) and must not create MySQL rows.
module OpsDbHelpers
  # Returns a hidden 'ops' HashConfig pointing to +path+.
  def temp_ops_db_config(path)
    ActiveRecord::DatabaseConfigurations::HashConfig.new(
      Rails.env, 'ops',
      { adapter: 'sqlite3', database: path.to_s, timeout: 5000, migrations_paths: 'db/ops_migrate',
        schema_dump: false, database_tasks: false }
    )
  end

  # Points Ops::Database to a temporary DB file (under +dir+) for the current example.
  def use_temp_ops_db(dir)
    config = temp_ops_db_config(File.join(dir, 'ops', "#{Rails.env}.sqlite3"))
    allow(Ops::Database).to receive(:db_config).and_return(config)
    Ops::Database.reset_state!
    config
  end
end

RSpec.configure do |config|
  config.include(OpsDbHelpers)
end
