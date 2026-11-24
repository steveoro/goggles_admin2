# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::MeetingPurge do
  let(:meeting) { GogglesDb::Meeting.find(18_222) }

  it "plans exactly the strategy's SQL without writing, the row counts as console and facts" do
    purger = Purge::Meeting.new(meeting:, stop_at_events: true)
    report = Maintenance::OutputCapture.capture { purger.display_report }.last
    purger.prepare
    operation = described_class.new(meeting_id: meeting.id, stop_at_events: '1')
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.significant_lines).to eq(plan.with(sql_lines: purger.single_transaction_sql_log).significant_lines)
    expect(operation.captured_output).to eq(report)
    expect(plan.summary['row_counts']).to eq(purger.row_counts.transform_keys(&:to_s))
    expect(operation.typed_token).to eq("PURGE #{meeting.id}")
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.file_base).to eq("purge_meeting-#{meeting.id}")
  end
end
