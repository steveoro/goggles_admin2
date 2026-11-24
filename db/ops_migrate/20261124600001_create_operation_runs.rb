# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3, phase 11): one maintenance operation run (Ops::OperationRun): a dry run ('preview'),
# a local apply ('apply', child of its preview) or a script-only run ('script_only', rake). Written only by
# Maintenance::Executor and the operations controllers; the history of the /operations page.
class CreateOperationRuns < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/AbcSize
    create_table :operation_runs do |t|
      t.string :operation_key, null: false
      t.json :params, null: false, default: {}
      t.string :params_digest
      t.string :mode, null: false
      t.integer :parent_run_id
      t.string :status, null: false, default: 'queued'
      t.string :refusal_reason
      t.string :label
      t.text :console
      t.json :summary, null: false, default: {}
      t.json :warnings, null: false, default: []
      t.json :error_messages, null: false, default: []
      t.text :sql_preview
      t.string :sql_digest
      t.boolean :applied_locally, null: false, default: false
      t.integer :sql_script_id
      t.integer :season_id
      t.string :subject_type
      t.integer :subject_id
      t.string :origin, null: false, default: 'ui'
      t.integer :health_finding_id
      t.boolean :drift_ack, null: false, default: false
      t.string :drift_verdict
      t.integer :started_by
      t.string :job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index %i[operation_key created_at]
      t.index :season_id
      t.index :health_finding_id
      t.index :parent_run_id
      t.index :status
    end
  end
end
