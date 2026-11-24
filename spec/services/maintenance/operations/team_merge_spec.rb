# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::TeamMerge do
  let(:source) { FactoryBot.create(:team) }
  let(:dest) { FactoryBot.create(:team) }

  it "plans exactly the strategy's SQL without writing, with the printed checker report as console" do
    merger = Merge::Team.new(source:, dest:, skip_columns: false, keep_as_alias: true)
    expect { merger.prepare }.to output.to_stdout
    operation = described_class.new(source_id: source.id, dest_id: dest.id, keep_as_alias: '1')
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(merger.sql_log)
    expect(plan.sql_lines).to include("DELETE FROM teams WHERE id=#{source.id};")
    expect(plan.console).to include(source.id.to_s)
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.file_base).to eq("merge_teams-#{source.id}-#{dest.id}")
  end

  it 'turns the failed badge sub-merge lines into warnings' do
    allow(Merge::Team).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap do |merger|
        allow(merger).to receive(:prepare) { merger.sql_log.push('-- WARNING: Badge merge failed for badge 1 => 2: boom', 'COMMIT;') }
      end
    end
    plan = described_class.new(source_id: source.id, dest_id: dest.id).plan
    expect(plan.warnings).to eq(['WARNING: Badge merge failed for badge 1 => 2: boom'])
  end

  it 'is prefilled from a team finding, and from the two teams of a possible badge duplicate' do
    teams = FactoryBot.build(:ops_health_finding, check_key: 'teams.possible_duplicates', payload: { 'rake' => { 'src' => 8, 'dest' => 3 } })
    expect(described_class.from_finding(teams).to_params).to eq('source_id' => 8, 'dest_id' => 3)
    badges = FactoryBot.build(:ops_health_finding, check_key: 'badges.duplicate.possible',
                                                   payload: { 'badges' => [{ 'id' => 1, 'team_id' => 5 }, { 'id' => 2, 'team_id' => 6 }] })
    expect(described_class.from_finding(badges).to_params).to eq('source_id' => 6, 'dest_id' => 5)
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan).to be_blocked
    expect(described_class.new(source_id: 0, dest_id: dest.id).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Team', id: 0)])
    expect(described_class.new(source_id: dest.id, dest_id: dest.id)).not_to be_valid
  end
end
