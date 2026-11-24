# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one DB sync check (Drift::Check), comparing the local DB with the remote API's
# 'tools/db_fingerprint' (count, max id, max updated_at per whitelisted table) into a verdict (green, amber, red,
# unknown) with its reasons (see Ops::DbFingerprint, Drift::Verdict). The status surfaces read only these rows.
# Only the last Ops::DbFingerprint::KEEP rows are kept.
class CreateDbFingerprints < ActiveRecord::Migration[8.1]
  def change
    create_table :db_fingerprints do |t|
      t.datetime :taken_at, null: false
      t.string :trigger, null: false, default: 'schedule'
      t.string :mode, null: false, default: 'full'
      t.string :api_base_url
      t.string :target_env
      t.string :api_version
      t.string :schema_version_local
      t.string :schema_version_remote
      t.json :local, null: false, default: {}
      t.json :remote, null: false, default: {}
      t.string :verdict, null: false
      t.json :reasons, null: false, default: []
      t.integer :pending_scripts_count, null: false, default: 0
      t.integer :remote_writes_count, null: false, default: 0
      t.float :duration
      t.text :error
      t.timestamps

      t.index :taken_at
      t.index %i[verdict taken_at]
      t.index %i[api_base_url taken_at]
    end
  end
end
