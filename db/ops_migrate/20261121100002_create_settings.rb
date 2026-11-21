# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): small key/value store (see Ops::Setting).
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false
      t.json :value
      t.timestamps

      t.index :key, unique: true
    end
  end
end
