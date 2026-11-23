# frozen_string_literal: true

# Ops DB: the operator's DB sync acknowledgement on a push run (phase 08: the tick of the Outbox confirmation page,
# re-checked by Outbox::Pusher before the first POST through Drift::Gate, scope :push).
class AddDriftAcknowledgedToPushRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :push_runs, :drift_acknowledged, :boolean, null: false, default: false
  end
end
