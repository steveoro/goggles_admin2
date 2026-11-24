# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::MeetingTeamFix do
  let(:meeting) { GogglesDb::Meeting.find(18_289) }
  let(:src_team) { GogglesDb::Team.find(913) }
  let(:dest_team) { GogglesDb::Team.find(1270) }

  it "plans exactly the strategy's SQL without writing, its preview report as console" do
    fixer = Merge::TeamInMeeting.new(meeting:, src_team:, dest_team:, full_report: false, index: 7)
    expected_report = Maintenance::OutputCapture.capture { fixer.display_report }.last
    fixer.prepare
    operation = described_class.new(meeting_id: meeting.id, source_team_id: src_team.id, dest_team_id: dest_team.id, index: 7)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(fixer.sql_log)
    expect(operation.captured_output).to eq(expected_report)
    expect(operation.file_base).to eq("merge_team_in_meeting-#{meeting.id}-913-to-1270")
    expect(operation.confirmation_for(plan)).to eq(:confirm)
    expect(plan.season_id).to eq(meeting.season_id)
  end

  it 'turns the strategy input errors into plan errors (the rake task printed "*** ERROR")' do
    operation = described_class.new(meeting_id: meeting.id, source_team_id: 913, dest_team_id: 913)
    plan = operation.plan
    expect(plan.errors).to eq(['Identical source and destination teams!'])
    expect(operation).to be_argument_error
  end
end
