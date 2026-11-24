# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): last computed value per key (see Ops::Snapshot).
class CreateSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :snapshots do |t|
      t.string :key, null: false
      t.json :payload, null: false
      t.string :source
      t.datetime :taken_at, null: false
      t.timestamps

      t.index :key, unique: true
    end
  end
end
