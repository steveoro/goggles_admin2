# frozen_string_literal: true

require 'rails_helper'

# The read-only inspectors (phase 13): each one's console is the report of its checker, nothing is written, no SQL.
RSpec.describe 'Maintenance::Inspectors' do
  include RakeParity::Fixtures

  before(:each) { hide_leftover_seasons! }

  def inspect_with(klass, **params)
    inspector = klass.new(**params)
    plan = nil
    expect(primary_db_statements { plan = inspector.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to be_empty
    [inspector, plan]
  end

  def report_of(checker)
    Maintenance::OutputCapture.capture do
      checker.run
      checker.display_report
    end.last
  end

  it 'team.check prints the team merge report' do
    inspector, = inspect_with(Maintenance::Inspectors::TeamCheck, source_id: 1, dest_id: 2)
    expect(inspector.captured_output).to eq(report_of(Merge::TeamChecker.new(source: GogglesDb::Team.find(1), dest: GogglesDb::Team.find(2))))
  end

  it 'swimmer.check prints the swimmer merge report' do
    inspector, = inspect_with(Maintenance::Inspectors::SwimmerCheck, source_id: 142, dest_id: 23)
    expected = report_of(Merge::SwimmerChecker.new(source: GogglesDb::Swimmer.find(142), dest: GogglesDb::Swimmer.find(23)))
    expect(inspector.captured_output).to eq(expected)
  end

  it 'badge.check prints the badge report (no destination: the category auto-fix)' do
    inspector, = inspect_with(Maintenance::Inspectors::BadgeCheck, source_id: RakeParity::Fixtures::BADGE_B)
    expect(inspector.captured_output).to eq(report_of(Merge::BadgeChecker.new(source: GogglesDb::Badge.find(RakeParity::Fixtures::BADGE_B), dest: nil)))
  end

  it 'season.badges lists the candidates only with list_teams or when there are none (the former task rule)' do
    duplicate_badge(RakeParity::Fixtures::BADGE_A)
    _inspector, plan = inspect_with(Maintenance::Inspectors::SeasonBadges, season_id: 182)
    expect(plan.summary).to include('sure_badge_merges' => 1, 'listed' => false)
    inspector, plan = inspect_with(Maintenance::Inspectors::SeasonBadges, season_id: 182, list_teams: '1')
    expect(plan.summary['listed']).to be(true)
    expect(inspector.captured_output).to include('SURE_BADGE_MERGES candidates w/ badge details:')
  end

  it 'team.map_badges, swimmer.map_mirs, team.dup_badges and meeting.dup_mir_badges print their tables' do
    inspector, plan = inspect_with(Maintenance::Inspectors::MapTeamBadges, season_id: 182, team_id: 54, page: 0)
    expect(inspector.captured_output).to include('--> Found 6 badges => showing page 0')
    expect(plan.summary['stopped']).to be(false)
    inspector, = inspect_with(Maintenance::Inspectors::MapSwimmerMirs, swimmer_id: 142, page: 0)
    expect(inspector.captured_output).to include('--> Swimmer ID 142', '=> showing page 0')
    inspector, = inspect_with(Maintenance::Inspectors::DupBadgesForTeam, team_id: 54)
    expect(inspector.captured_output).to be_present
    duplicate_mir(18_222)
    inspector, plan = inspect_with(Maintenance::Inspectors::DupMIRBadges, meeting_id: 18_222)
    expect(inspector.captured_output).to include('--> Found 1 badges with > 1 MIR for the *SAME* MeetingProgram.')
    expect(plan.summary['badges']).to eq(1)
  end

  it 'gives errors without raising for unknown ids' do
    expect(Maintenance::Inspectors::TeamCheck.new(source_id: 0, dest_id: 2).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Team', id: 0)])
    expect(Maintenance::Inspectors::DupMIRBadges.new(meeting_id: 0).plan).to be_blocked
  end
end
