# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::MeetingSetCancelled do
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:, cancelled: false) }
  let(:calendar) { FactoryBot.create(:calendar, season:, meeting:, cancelled: false) }

  it 'plans one SqlMaker UPDATE per row to flag, in the calendar-linker wrapper, without writing' do
    operation = described_class.new(meeting_id: meeting.id, calendar_id: calendar.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expected = [meeting, calendar].map { |row| SqlMaker.new(row:).log_update('cancelled' => true, 'updated_at' => nil) }
    expect(plan.sql_lines[5..6]).to eq(expected)
    expect(plan.sql_lines).to include('START TRANSACTION;', 'COMMIT;')
    expect(plan).to have_attributes(errors: [], season_id: season.id, health_group: 'meetings')
    expect(plan.summary).to include('meeting_id' => meeting.id, 'calendar_id' => calendar.id, 'mirs' => 0, 'mrrs' => 0)
    expect(operation.file_base).to eq("meeting_cancel-#{meeting.id}")
    expect(operation.confirmation_for(plan)).to eq(:one_click)
    expect(meeting.reload.cancelled).to be(false)
  end

  it 'refuses a meeting with results, and has nothing to do for rows already cancelled' do
    health_add_mir(meeting)
    expect(described_class.new(meeting_id: meeting.id).plan.errors).to eq([I18n.t('maintenance.operations.meeting_set_cancelled.errors.has_results')])

    other = FactoryBot.create(:meeting, season:, cancelled: true)
    plan = described_class.new(meeting_id: other.id).plan
    expect(plan).to be_empty
    expect(plan).not_to be_blocked
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan.errors).to eq([I18n.t('maintenance.operations.meeting_set_cancelled.errors.no_target')])
    expect(described_class.new(meeting_id: 0).plan.errors.first).to include('0')
    other_calendar = FactoryBot.create(:calendar, season:, cancelled: false)
    expect(described_class.new(meeting_id: meeting.id, calendar_id: other_calendar.id).plan).to be_blocked
  end

  it 'is prefilled from the finding payload cancel target, flagging a calendar alone' do
    finding = FactoryBot.build(:ops_health_finding, check_key: 'calendars.unlinked', payload: { 'cancel' => { 'calendar_id' => calendar.id } })
    operation = described_class.from_finding(finding)
    expect(operation.to_params).to eq('calendar_id' => calendar.id)
    expect(operation.file_base).to eq("calendar_cancel-#{calendar.id}")
    expect(operation.plan.sql_lines.grep(/UPDATE `calendars`/).size).to eq(1)
  end

  it 'flags the rows when the planned SQL runs (Executor apply)' do
    data_root = Pathname.new(Dir.mktmpdir)
    operation = described_class.new(meeting_id: meeting.id, calendar_id: calendar.id)
    preview = FactoryBot.create(:ops_operation_run, operation_key: described_class.key, params: operation.to_params)
    Maintenance::Executor.new(run: preview, data_root:, gate: maintenance_gate(:ok), sql_runner: maintenance_sql_runner).call
    apply = FactoryBot.create(:ops_operation_run, operation_key: described_class.key, params: operation.to_params, mode: 'apply',
                                                  parent_run_id: preview.id)
    Maintenance::Executor.new(run: apply, data_root:, gate: maintenance_gate(:ok), sql_runner: maintenance_inline_sql_runner,
                              tmp_dir: data_root.join('tmp')).call
    expect(apply.reload).to be_succeeded
    expect([meeting.reload.cancelled, calendar.reload.cancelled]).to eq([true, true])
    expect(Ops::SqlScript.sole).to have_attributes(kind: 'cancel_flag', folder: 'misc', filename: end_with("-meeting_cancel-#{meeting.id}.sql"))
  ensure
    FileUtils.rm_rf(data_root) if data_root
  end
end
