# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): the stored verdict of one Data-Fix phase of a source (see Ops::PhaseVerdict,
# DataFix::Verdict). Recomputable from the phase files, except operator_edited_at, which mirrors the edit marker
# kept in the phase file '_meta' (the file stays authoritative).
class CreatePhaseVerdicts < ActiveRecord::Migration[8.1]
  def change
    create_table :phase_verdicts do |t|
      t.references :pipeline_source, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :phase, null: false
      t.string :status, null: false
      t.integer :issues_count, null: false, default: 0
      t.json :issues, null: false, default: []
      t.json :counts, null: false, default: {}
      t.json :new_entities, null: false, default: {}
      t.string :built_by
      t.datetime :built_at
      t.string :built_digest
      t.json :input_digests, null: false, default: {}
      t.datetime :operator_edited_at
      t.integer :confirmed_count
      t.integer :db_generation
      t.string :fingerprint
      t.datetime :checked_at
      t.timestamps

      t.index %i[pipeline_source_id phase], unique: true
      t.index :status
    end
  end
end
