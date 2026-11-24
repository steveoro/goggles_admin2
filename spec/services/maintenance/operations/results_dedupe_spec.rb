# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::ResultsDedupe do
  include ActiveSupport::Testing::TimeHelpers

  let(:meeting) { FactoryBot.create(:meeting) }
  let(:program) { health_individual_program(meeting) }
  let(:badge) { FactoryBot.create(:badge, season: meeting.season) }

  # Two MIRs of the same swimmer in the same program (same timing unless +other_seconds+).
  def duplicate_mirs(other_seconds: nil)
    first = FactoryBot.create(:meeting_individual_result, meeting_program: program, badge:, seconds: 30, hundredths: 10, minutes: 0)
    second = FactoryBot.create(:meeting_individual_result, meeting_program: program, badge:, minutes: 0,
                                                           seconds: other_seconds || 30, hundredths: 10)
    [first, second]
  end

  def strategy_log
    cleaner = Merge::DuplicateResultCleaner.new(meeting: GogglesDb::Meeting.find(meeting.id), autofix: true)
    cleaner.prepare
    cleaner.single_transaction_sql_log
  end

  it "plans exactly the cleaner's SQL without writing, one click when every MIR group has the same timing" do
    freeze_time do
      _first, second = duplicate_mirs
      operation = described_class.new(meeting_id: meeting.id)
      plan = nil
      expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
      expect(plan.sql_lines).to eq(strategy_log)
      expect(plan.sql_lines).to include("DELETE FROM meeting_individual_results WHERE id = #{second.id}; -- keeping #{second.id - 1}")
      expect(plan.summary['counts']).to include('mirs' => 1)
      expect(plan.summary['mir_groups'].sole).to include('timing_match' => true, 'mir_ids' => [second.id - 1, second.id])
      expect(operation.confirmation_for(plan)).to eq(:one_click)
      expect(operation.follow_ups(plan)).to eq([{ 'operation_key' => 'ranks.recompute', 'params' => { 'meeting_id' => meeting.id } }])
    end
  end

  it 'asks for the typed confirmation when the timings differ' do
    duplicate_mirs(other_seconds: 31)
    operation = described_class.new(meeting_id: meeting.id)
    plan = operation.plan
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.typed_token).to eq("DEDUPE #{meeting.id}")
    expect(plan.warnings).to include(I18n.t('maintenance.operations.results_dedupe.warnings.timing_mismatch'))
  end

  it 'asks for the typed confirmation when a group beyond the listed ones (MAX_GROUPS) has different timings' do
    fake_mir = Struct.new(:id, :badge_id, :to_timing)
    swimmer = FactoryBot.create(:swimmer)
    groups = (1..(described_class::MAX_GROUPS + 7)).map do |index|
      mismatch = index == described_class::MAX_GROUPS + 7
      { swimmer:, meeting_program_id: index, timing_match: !mismatch,
        mirs: [fake_mir.new(index * 10, nil, Timing.new(seconds: 30)), fake_mir.new((index * 10) + 1, nil, Timing.new(seconds: mismatch ? 31 : 30))] }
    end
    allow_any_instance_of(Merge::DuplicateResultCleaner).to receive(:find_duplicate_mirs).and_return(groups) # rubocop:disable RSpec/AnyInstance
    operation = described_class.new(meeting_id: meeting.id)
    plan = operation.plan
    expect(plan.summary['mir_groups'].size).to eq(described_class::MAX_GROUPS)
    expect(plan.summary['mir_groups']).to all(include('timing_match' => true))
    expect(plan.summary).to include('mir_groups_total' => described_class::MAX_GROUPS + 7, 'timing_mismatch_count' => 1)
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(plan.warnings).to include(I18n.t('maintenance.operations.results_dedupe.warnings.timing_mismatch'),
                                     I18n.t('maintenance.operations.results_dedupe.warnings.groups_capped', count: described_class::MAX_GROUPS + 7))
  end

  it 'has nothing to do (Plan#empty?) for a meeting without duplicates, whatever the wrapper length' do
    health_add_mir(meeting)
    plan = described_class.new(meeting_id: meeting.id).plan
    expect(plan).to be_empty
    expect(plan.sql_lines.size).to be > 5
  end

  it 'is refused while the meeting has an open NULL swimmers finding' do
    duplicate_mirs
    FactoryBot.create(:ops_health_finding, season_id: meeting.season_id, group_key: 'results', check_key: 'results.null_swimmers',
                                           subject_id: meeting.id)
    plan = described_class.new(meeting_id: meeting.id).plan
    expect(plan.errors).to eq([I18n.t('maintenance.operations.results_dedupe.errors.null_swimmers_first')])
    expect(plan.sql_lines).to be_empty
  end

  it 'gives errors without raising for invalid params and is prefilled from a finding' do
    expect(described_class.new.plan).to be_blocked
    expect(described_class.new(meeting_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Meeting', id: 0)])
    finding = FactoryBot.build(:ops_health_finding, check_key: 'results.dup_mir_per_badge', subject_id: 77, payload: {})
    expect(described_class.from_finding(finding).to_params).to eq('meeting_id' => 77)
  end
end
