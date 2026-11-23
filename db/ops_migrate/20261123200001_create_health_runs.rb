# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one data health check run per season and group (see Ops::HealthRun,
# Health::Runner). Only the last Ops::HealthRun::KEPT_PER_GROUP rows per (season, group) are kept.
class CreateHealthRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :health_runs do |t|
      t.integer :season_id, null: false
      t.string :group_key, null: false
      t.string :trigger, null: false
      t.string :status, null: false, default: 'queued'
      t.json :check_versions, null: false, default: {}
      t.string :stamp
      t.json :counts, null: false, default: {}
      t.integer :findings_count, null: false, default: 0
      t.integer :new_count, null: false, default: 0
      t.integer :resolved_count, null: false, default: 0
      t.integer :duration_ms
      t.integer :db_epoch
      t.text :error_message
      t.string :job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index %i[season_id group_key finished_at]
      t.index %i[status finished_at]
    end
  end
end
