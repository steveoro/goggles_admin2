# frozen_string_literal: true

# Ops DB (phase 10, pipeline automation):
# - pipeline_sources.auto_prepare: the per-row hold of the Season board (false = the planner never queues a prepare);
# - pipeline_sources.failed_source_sha256: SHA256 of the source when its last prepare failed (the planner re-queues a
#   failed source only after the source changed);
# - an index on pipeline_runs (kind, subject_key, status), for the extraction-attempt count per manifest PDF.
class AddAutomationToPipelineSources < ActiveRecord::Migration[8.1]
  def change
    # (SQLite has no bulk ALTER TABLE: change_table bulk: would run the same statements)
    # rubocop:disable-next Rails/BulkChangeTable
    add_column :pipeline_sources, :auto_prepare, :boolean, null: false, default: true
    add_column :pipeline_sources, :failed_source_sha256, :string
    add_index :pipeline_runs, %i[kind subject_key status]
  end
end
