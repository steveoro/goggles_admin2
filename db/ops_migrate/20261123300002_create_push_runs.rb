# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one Outbox push run (see Ops::PushRun, Outbox::PushJob), started only by an
# operator click on the Outbox confirmation page.
class CreatePushRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :push_runs do |t|
      t.integer :user_id
      t.string :target_api_url
      t.string :target_env
      t.json :script_ids, null: false, default: []
      t.string :status, null: false, default: 'running'
      t.integer :pushed_count, null: false, default: 0
      t.integer :stopped_at_script_id
      t.text :error
      t.boolean :override_order, null: false, default: false
      t.string :job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index :started_at
      t.index :status
    end
  end
end
