# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::BadgeTeamFix do
  include RakeParity::Fixtures

  before(:each) { hide_leftover_seasons! }

  let(:badge) { GogglesDb::Badge.find(RakeParity::Fixtures::BADGE_B) }
  let(:new_team) { GogglesDb::Team.find(1193) }

  it "plans exactly the strategy's SQL without writing, its report as console" do
    fixer = Merge::TeamInBadge.new(badges: [badge], new_team:, nuke_team: false)
    report = Maintenance::OutputCapture.capture { fixer.display_report }.last
    fixer.prepare
    operation = described_class.new(badge_ids: " #{badge.id}, 0", team_id: new_team.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(fixer.sql_log)
    expect(operation.captured_output).to eq(report)
    expect(operation.file_base).to eq("fix_team_in_badge-#{badge.id}")
    expect(operation.confirmation_for(plan)).to eq(:confirm)
    expect(plan.season_id).to eq(badge.season_id)
  end

  it 'asks for the typed confirmation with nuke_team' do
    operation = described_class.new(badge_ids: badge.id.to_s, team_id: new_team.id, nuke_team: '1')
    expect(operation.confirmation_for(nil)).to eq(:typed)
    expect(operation.typed_token).to eq("NUKE TEAM #{new_team.id}")
  end

  it 'blocks the plan when the strategy refuses (a swimmer already on the new team: merge instead)' do
    plan = described_class.new(badge_ids: badge.id.to_s, team_id: badge.team_id).plan
    expect(plan).to be_blocked
    expect(described_class.new(badge_ids: '0', team_id: 1).plan.errors).to eq([I18n.t('maintenance.operations.badge_team_fix.errors.no_badges')])
  end
end
