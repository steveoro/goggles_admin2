# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): the operator's web sessions (activerecord-session_store rows, written through
# Ops::SessionStoreSetup::OpsSession), so that a sign-in survives a guided restore of the local MySQL DB
# (phase 14). Same shape as the engine's MySQL 'sessions' table (left in place, unused while the ops DB is ready).
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.string :session_id, null: false
      t.text :data
      t.timestamps

      t.index :session_id, unique: true
      t.index :updated_at
    end
  end
end
