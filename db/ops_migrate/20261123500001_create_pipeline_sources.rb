# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): one row per Data-Fix source (see Ops::PipelineSource, DataFix::Pipeline), keyed by
# the SeasonBoard::DiskIndex base name, which stays stable from results.new to results.done and covers non-FIN
# sources. Holds the overall stage, the review summary and the build lease. Rebuildable from disk (rake ops:rebuild).
class CreatePipelineSources < ActiveRecord::Migration[8.1]
  def change
    create_table :pipeline_sources do |t|
      t.integer :season_id, null: false
      t.string :base, null: false
      t.string :fin_event_id
      t.string :source_kind
      t.string :source_path
      t.string :source_sha256
      t.string :stage, null: false, default: 'new'
      t.string :stage_reason
      t.json :stage_details, null: false, default: {}
      t.integer :review_phase
      t.integer :review_count
      t.integer :new_teams_count
      t.integer :new_swimmers_count
      t.integer :db_generation
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.datetime :prepared_at
      t.datetime :committed_at
      t.timestamps

      t.index %i[season_id base], unique: true
      t.index :fin_event_id
      t.index :stage
    end
  end
end
