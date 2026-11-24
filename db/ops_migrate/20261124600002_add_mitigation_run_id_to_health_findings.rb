# frozen_string_literal: true

# Ops DB (phase 11): the operation run (Ops::OperationRun, apply mode) that last applied a fix for the finding.
class AddMitigationRunIdToHealthFindings < ActiveRecord::Migration[8.1]
  # rubocop:disable-next Rails/BulkChangeTable -- one column and its index (SQLite)
  def change
    add_column :health_findings, :mitigation_run_id, :integer
    add_index :health_findings, :mitigation_run_id
  end
end
