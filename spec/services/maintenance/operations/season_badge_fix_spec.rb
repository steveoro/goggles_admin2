# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::SeasonBadgeFix do
  include RakeParity::Fixtures

  before(:each) { hide_leftover_seasons! }

  it 'plans one step of Merge::SeasonBadgeFixer without writing, with the counts per step and the badges' do
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    operation = described_class.new(season_id: 182)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    fixer = Merge::SeasonBadgeFixer.new(season: GogglesDb::Season.find(182)).prepare
    expect(plan.sql_lines).to eq(fixer.sql_log)
    expect(plan.summary).to include('step' => 'sure', 'step_number' => 1, 'planned' => 1, 'deferred' => 0,
                                    'candidates' => { 'sure' => 1, 'relay_only' => 0, 'relay' => 0 })
    expect(plan.summary['badges'].sole).to include('source_id' => copy.id, 'dest_id' => RakeParity::Fixtures::BADGE_A, 'status' => 'planned')
    expect(operation.file_base).to eq('season_fix_182-step1-sure')
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.typed_token).to eq('FIX SEASON 182')
    expect(operation.follow_ups(plan)).to eq([{ 'operation_key' => 'season.badge_fix', 'params' => { 'season_id' => 182 } }])
  end

  it 'reports its progress while planning and stops when cancelled' do
    duplicate_badge(RakeParity::Fixtures::BADGE_A)
    operation = described_class.new(season_id: 182)
    calls = []
    operation.progress_reporter = ->(done, total, label) { calls << [done, total, label] }
    operation.plan
    expect(calls.first).to eq([0, 1, "'sure badge merges': badge #{GogglesDb::Badge.maximum(:id)}"])
    operation = described_class.new(season_id: 182)
    operation.progress_reporter = ->(*) { raise Maintenance::Cancelled }
    expect { operation.plan }.to raise_error(Maintenance::Cancelled)
  end

  it 'needs a source team for the possible merges and for a destination team' do
    expect(described_class.new(season_id: 182,
                               include_possible: '1').plan.errors.join).to include(I18n.t('maintenance.operations.season_badge_fix.errors.possible_without_team'))
    expect(described_class.new(season_id: 182, dest_team_id: 5).plan).to be_blocked
    expect(described_class).to be_cancellable
    expect(described_class).to be_season_wide
  end
end
