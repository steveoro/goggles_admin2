# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::CodedNamesNormalize do
  it "plans exactly the strategy's SQL without writing, with its statistics" do
    GogglesDb::Meeting.where(id: 1).update_all(code: 'parity-not-normalized') # rubocop:disable Rails/SkipsModelValidations
    normalizer = Normalize::CodedNames.new(limit: 5).call
    operation = described_class.new(limit: 5)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(normalizer.single_transaction_sql_log)
    expect(plan).not_to be_empty
    expect(plan.summary['stats']).to eq(normalizer.stats.transform_keys(&:to_s))
    expect(plan.summary['changes']).to eq(normalizer.change_log)
    expect(operation.file_base).to eq('normalize_coded_names')
    expect(operation.confirmation_for(plan)).to eq(:typed)
  end

  it 'refuses a negative limit' do
    expect(described_class.new(limit: -1).plan).to be_blocked
  end
end
