# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::ResultsNullSwimmersFix do
  include ActiveSupport::Testing::TimeHelpers

  let(:meeting) { FactoryBot.create(:meeting) }

  def null_swimmer_mir(**attributes)
    mir = health_add_mir(meeting)
    mir.update_columns(swimmer_id: nil, **attributes) # rubocop:disable Rails/SkipsModelValidations
    mir
  end

  it "plans the fixer's statements in the fix.rake transaction, without writing" do
    freeze_time do
      null_swimmer_mir
      plan = nil
      expect(primary_db_statements { plan = described_class.new(meeting_id: meeting.id).plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
      fixer = Fix::NullSwimmersInMeeting.new(meeting: GogglesDb::Meeting.find(meeting.id))
      expected = ["-- Fix null swimmers - Meeting #{meeting.id}", "-- Generated: #{Time.zone.now}", '', 'SET AUTOCOMMIT = 0;',
                  'START TRANSACTION;', '', *fixer.prepare, '', 'COMMIT;']
      expect(plan.sql_lines).to eq(expected)
      expect(plan.summary['report']['mirs']).to include('fixable' => 1, 'unfixable' => 0)
      expect(plan).not_to be_empty
    end
  end

  it 'lists the unfixable rows and never touches them' do
    null_swimmer_mir(badge_id: nil)
    plan = described_class.new(meeting_id: meeting.id).plan
    expect(plan).to be_empty
    expect(plan.summary['unfixable'].sole).to match(/MIR \d+: no badge/)
    expect(plan.warnings).to eq([I18n.t('maintenance.operations.results_null_swimmers_fix.warnings.unfixable', count: 1)])
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan).to be_blocked
    expect(described_class.new(meeting_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Meeting', id: 0)])
  end
end
