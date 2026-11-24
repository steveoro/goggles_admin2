# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::SwimmerMerge do
  let(:source) { FactoryBot.create(:swimmer) }
  let(:dest) { FactoryBot.create(:swimmer, gender_type_id: source.gender_type_id, year_of_birth: source.year_of_birth) }

  it "plans exactly the strategy's SQL without writing, always with the typed confirmation" do
    merger = Merge::Swimmer.new(source:, dest:, skip_columns: false, force: false)
    Maintenance::OutputCapture.capture { merger.prepare } # (the strategy may print its checker report)
    expected = merger.sql_log
    operation = described_class.new(source_id: source.id, dest_id: dest.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.errors).to be_empty
    expect(plan.sql_lines).to eq(expected)
    expect(plan.sql_lines.join).to include("DELETE FROM swimmers WHERE id=#{source.id};")
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.typed_token).to eq("MERGE #{source.id} INTO #{dest.id}")
    expect(operation.file_base).to eq("merge_swimmers-#{source.id}-#{dest.id}")
    expect(plan.health_group).to eq('people')
  end

  it 'blocks on checker errors unless forced, keeping the checker report' do
    other = FactoryBot.create(:swimmer, gender_type_id: GogglesDb::GenderType.where.not(id: source.gender_type_id).first.id)
    plan = described_class.new(source_id: source.id, dest_id: other.id).plan
    expect(plan.errors.first).to eq(I18n.t('maintenance.operations.swimmer_merge.errors.checker'))
    expect(plan.errors.join).to include('Gender mismatch')
    expect(plan.console).to be_present
    expect(plan.sql_lines).to be_empty

    forced = described_class.new(source_id: source.id, dest_id: other.id, force: '1').plan
    expect(forced.errors).to be_empty
    expect(forced.warnings.join).to include('Gender mismatch')
    expect(forced).not_to be_empty
  end

  it 'gives errors without raising for invalid params and is prefilled from a possible-duplicate finding' do
    expect(described_class.new(source_id: source.id).plan).to be_blocked
    expect(described_class.new(source_id: source.id, dest_id: source.id)).not_to be_valid
    expect(described_class.new(source_id: 0, dest_id: dest.id).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: 0)])
    expect(described_class.new(source_id: source.id, dest_id: dest.id, force: '0')).not_to be_valid
    finding = FactoryBot.build(:ops_health_finding, check_key: 'swimmers.possible_duplicates', payload: { 'rake' => { 'src' => 9, 'dest' => 4 } })
    expect(described_class.from_finding(finding).to_params).to eq('source_id' => 9, 'dest_id' => 4)
  end
end
