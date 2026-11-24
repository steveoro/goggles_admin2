# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one data health finding per season, check and subject (see Ops::HealthFinding,
# Health::FindingSync). The fingerprint hashes the check key, the season and the subject's entity ids only, so
# the operator's triage (acknowledged / ignored, note) survives the next runs.
class CreateHealthFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :health_findings do |t|
      t.integer :season_id, null: false
      t.string :group_key, null: false
      t.string :check_key, null: false
      t.string :fingerprint, null: false
      t.string :severity, null: false
      t.string :status, null: false, default: 'open'
      t.string :subject_type
      t.integer :subject_id
      t.string :subject_ids
      t.string :title
      t.json :payload, null: false, default: {}
      t.string :payload_digest
      t.text :note
      t.datetime :status_changed_at
      t.integer :status_changed_by
      t.integer :first_seen_run_id
      t.integer :last_seen_run_id
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.datetime :resolved_at
      t.timestamps

      t.index %i[season_id check_key fingerprint], unique: true
      t.index %i[season_id group_key status]
      t.index %i[status severity]
    end
  end
end
