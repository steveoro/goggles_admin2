# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one Data-Fix pipeline run (build, prepare, refresh, commit, extract) with its
# throttled progress (see Ops::PipelineRun): what the UI reads instead of ImportStatusChannel for background work,
# plus stale-run detection and history. Keyed by subject_key (base, FIN id or PDF name). Not rebuildable.
class CreatePipelineRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :pipeline_runs do |t|
      t.references :pipeline_source, foreign_key: { on_delete: :nullify }
      t.string :subject_key, null: false
      t.string :kind, null: false
      t.string :origin, null: false
      t.string :status, null: false, default: 'queued'
      t.integer :phase
      t.integer :progress
      t.integer :total
      t.string :message
      t.text :error
      t.string :job_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps

      t.index %i[subject_key kind created_at]
      t.index :status
    end
  end
end
