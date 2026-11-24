# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): append-only operator/job/system event log.
# Pruned after Ops::Database::EVENT_RETENTION by 'ops:prepare'.
class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.datetime :occurred_at, null: false
      t.string :kind, null: false
      t.string :level, null: false, default: 'info'
      t.string :actor, null: false, default: 'system'
      t.integer :season_id
      t.string :subject_type
      t.string :subject_key
      t.json :data, null: false, default: {}
      t.string :link_path
      t.datetime :created_at, null: false

      t.index :occurred_at
      t.index %i[kind occurred_at]
      t.index %i[subject_type subject_key]
    end
  end
end
