# frozen_string_literal: true

# Ops DB (phase 13): the operator's state of the season-start checklist steps (Ops::SeasonChecklistItem,
# Maintenance::SeasonStart::Checklist). One row per (season_id, step_key); the steps checked from data re-derive their
# state on every view, so a row there only records who confirmed or skipped what.
class CreateSeasonChecklistItems < ActiveRecord::Migration[8.1]
  def change
    create_table :season_checklist_items do |t|
      t.integer :season_id, null: false
      t.string :step_key, null: false
      t.string :status, null: false, default: 'pending'
      t.text :note
      t.integer :done_by
      t.datetime :done_at
      t.integer :operation_run_id
      t.timestamps

      t.index %i[season_id step_key], unique: true
    end
  end
end
