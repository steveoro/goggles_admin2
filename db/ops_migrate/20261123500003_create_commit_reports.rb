# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one Phase 6 commit request and its outcome (see Ops::CommitReport,
# DataFixCommitJob, DataFix::CommitRunner). Created only by the operator's Commit click; reopenable by id.
# Not unique per source (re-imports happen) and not rebuildable.
class CreateCommitReports < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/AbcSize
    create_table :commit_reports do |t|
      t.references :pipeline_source, foreign_key: { on_delete: :nullify }
      t.integer :season_id
      t.string :source_base, null: false
      t.string :source_path
      t.string :status, null: false, default: 'queued'
      t.integer :requested_by_user_id, null: false
      t.datetime :requested_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.string :job_id
      t.json :preflight, null: false, default: {}
      t.json :summary, null: false, default: {}
      t.json :stats, null: false, default: {}
      t.text :error_message
      t.text :archive_error
      t.integer :first_error_phase
      t.string :log_rel_path
      t.string :sql_rel_path
      t.integer :sql_script_id
      t.string :done_dir
      t.integer :meeting_id
      t.json :health_run_ids, null: false, default: {}
      t.json :post_commit_checks
      t.integer :db_generation_after
      t.string :progress_message
      t.integer :progress_current
      t.integer :progress_total
      t.timestamps

      t.index :status
      t.index %i[source_base created_at]
    end
  end
end
