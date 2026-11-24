# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::RanksRecompute do
  let(:meeting) { FactoryBot.create(:meeting) }

  it 'plans the Recompute::Ranks SQL of a meeting without writing' do
    program = health_individual_program(meeting)
    FactoryBot.create(:meeting_individual_result, meeting_program: program, minutes: 0, seconds: 40, hundredths: 0, rank: 1)
    FactoryBot.create(:meeting_individual_result, meeting_program: program, minutes: 0, seconds: 30, hundredths: 0, rank: 2)
    operation = described_class.new(meeting_id: meeting.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(Recompute::Ranks.new(meeting: GogglesDb::Meeting.find(meeting.id)).call.sql_log)
    expect(plan.summary).to include('updates' => 2, 'updates_by_meeting' => { meeting.id.to_s => 2 })
    expect(plan).to have_attributes(season_id: meeting.season_id, health_group: nil)
    expect(operation.file_base).to eq("recompute_ranks-meeting_#{meeting.id}")
    expect(operation.to_params).to eq('meeting_id' => meeting.id)
  end

  it 'targets a whole season with season_id (never derived from the meeting)' do
    operation = described_class.new(season_id: meeting.season_id)
    expect(operation.file_base).to eq("recompute_ranks-season_#{meeting.season_id}")
    expect(operation.subject).to eq(['season', meeting.season_id])
    expect(described_class.new(meeting_id: meeting.id).subject).to eq(['meeting', meeting.id])
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan.errors).to eq([I18n.t('maintenance.operations.ranks_recompute.errors.no_target')])
    expect(described_class.new(meeting_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Meeting', id: 0)])
  end
end
