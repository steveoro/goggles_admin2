# frozen_string_literal: true

# Ops DB (phase 13): progress and cancel of a long operation run (Maintenance::Executor, 'season.badge_fix'):
# +progress+ ({ done, total, label }, written while planning) and +cancel_requested_at+ (the operator's Cancel click;
# the run then stops at its next progress report, refused 'cancelled').
class AddProgressToOperationRuns < ActiveRecord::Migration[8.1]
  def change
    change_table :operation_runs, bulk: true do |t|
      t.json :progress
      t.datetime :cancel_requested_at
    end
  end
end
