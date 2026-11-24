# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one guided restore of the local MySQL DB from a production dump (phase 14; see
# Ops::RestoreRun, DbRestoreController, DbRestore::*). Lives in the ops DB because a restore never touches it.
class CreateRestoreRuns < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/AbcSize
    create_table :restore_runs do |t|
      t.string :status, null: false, default: 'draft'
      t.string :step
      t.string :mode, null: false, default: 'wizard'
      t.string :dump_path
      t.string :dump_sha256
      t.bigint :dump_bytes
      t.datetime :dump_taken_at
      t.string :dump_schema_version
      t.json :dump_tables, null: false, default: []
      t.integer :dump_iq_next_id
      t.json :inspection, null: false, default: {}
      t.string :snapshot_path
      t.string :ops_backup_path
      t.string :target_database
      t.json :confirmations, null: false, default: {}
      t.json :preserved, null: false, default: {}
      t.json :outcome, null: false, default: {}
      t.bigint :progress_bytes, null: false, default: 0
      t.text :log
      t.text :error
      t.string :job_id
      t.string :progress_token_digest
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :user_id
      t.timestamps

      t.index :status
      t.index :started_at
    end
  end
end
