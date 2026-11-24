# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): the SQL Outbox registry, one row per SQL script that changes the local DB
# (see Ops::SqlScript, Outbox::Writer, Outbox::Reconciler). The file on disk stays the source of truth for
# pending vs sent; the row holds what the disk can't (global order, remote id, target, outcome).
class CreateSqlScripts < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/AbcSize
    create_table :sql_scripts do |t|
      t.integer :seq, null: false
      t.string :rel_path, null: false
      t.string :filename, null: false
      t.string :folder, null: false
      t.integer :season_id
      t.string :kind, null: false
      t.string :sha256, null: false
      t.integer :byte_size
      t.datetime :file_mtime
      t.string :state, null: false
      t.string :previous_state
      t.string :held_reason
      t.boolean :applied_locally # rubocop:disable Rails/ThreeStateBooleanColumn -- nil = unknown (adopted files)
      t.boolean :single_transaction # rubocop:disable Rails/ThreeStateBooleanColumn -- nil = not checked
      t.json :origin, null: false, default: {}
      t.string :target_api_url
      t.string :target_env
      t.integer :remote_iq_id
      t.integer :push_attempts, null: false, default: 0
      t.datetime :pushed_at
      t.datetime :remote_checked_at
      t.datetime :resolved_at
      t.text :last_error
      t.boolean :changed_after_push, null: false, default: false
      t.text :note
      t.timestamps

      t.index :seq, unique: true
      t.index :rel_path, unique: true
      t.index :sha256
      t.index %i[state seq]
      t.index :season_id
      t.index :kind
      t.index :remote_iq_id
    end
  end
end
