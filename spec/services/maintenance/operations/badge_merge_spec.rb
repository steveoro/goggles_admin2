# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::BadgeMerge do
  # (the fixtures of spec/strategies/merge/badge_spec.rb)
  let(:season) { FactoryBot.create(:season) }
  let(:category_type) { FactoryBot.create(:category_type, season:) }
  let(:team_affiliation) { FactoryBot.create(:team_affiliation, season:) }
  let(:team) { team_affiliation.team }
  let(:dest_badge) { FactoryBot.create(:badge, season:, category_type:, team_affiliation:, team:) }
  let(:src_badge) { FactoryBot.create(:badge, season:, category_type:, team_affiliation:, team:) }

  def strategy_log(**options)
    merger = Merge::Badge.new(source: src_badge.decorate, dest: dest_badge.decorate, **options)
    merger.prepare
    merger.single_transaction_sql_log
  end

  it "plans exactly the strategy's single-transaction SQL, without writing; one click for the same team and category" do
    operation = described_class.new(source_id: src_badge.id, dest_id: dest_badge.id)
    expected = strategy_log
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(expected)
    expect(plan).to have_attributes(errors: [], season_id: season.id, health_group: 'badges')
    expect(plan.summary['source']).to include('id' => src_badge.id, 'team_id' => team.id)
    expect(operation.confirmation_for(plan)).to eq(:one_click)
    expect(operation.file_base).to eq("merge_badges-#{src_badge.id}-#{dest_badge.id}")
    expect(operation.typed_token).to eq("MERGE #{src_badge.id} INTO #{dest_badge.id}")
  end

  context 'with different teams' do
    let(:other_team) { FactoryBot.create(:team) }
    let(:other_affiliation) { FactoryBot.create(:team_affiliation, team: other_team, season:) }

    before(:each) { src_badge.update!(team: other_team, team_affiliation: other_affiliation) }

    it 'is blocked without an override, keeping the checker report printed before the raise' do
      plan = described_class.new(source_id: src_badge.id, dest_id: dest_badge.id).plan
      expect(plan.errors).to eq(['Unrecoverable errors detected! Cannot continue.'])
      expect(plan.console).to be_present
      expect(plan.sql_lines).to be_empty
    end

    it 'passes the flags as true (never "1") and asks for the typed confirmation' do
      operation = described_class.new(source_id: src_badge.id, dest_id: dest_badge.id, keep_dest_team: '1')
      plan = operation.plan
      expect(plan.sql_lines).to eq(strategy_log(keep_dest_team: true))
      expect(operation.to_params).to eq('source_id' => src_badge.id, 'dest_id' => dest_badge.id, 'keep_dest_team' => true)
      expect(operation.confirmation_for(plan)).to eq(:typed)
    end
  end

  it 'rejects "0" (and any value but 1, true or empty) for a flag' do
    operation = described_class.new(source_id: src_badge.id, dest_id: dest_badge.id, force: '0', autofix: 'false')
    expect(operation).not_to be_valid
    expect(operation.plan.errors.size).to eq(2)
    expect(described_class.new(source_id: src_badge.id, dest_id: dest_badge.id, force: '', autofix: true)).to be_valid
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan.errors.first).to include(I18n.t('maintenance.params.source_id'))
    expect(described_class.new(source_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Badge', id: 0)])
    expect(described_class.new(source_id: src_badge.id, dest_id: src_badge.id)).not_to be_valid
  end

  it 'is prefilled from a sure-merge finding (dest = first, source = second, autofix) and from a relay finding (no dest)' do
    sure = FactoryBot.build(:ops_health_finding, check_key: 'badges.duplicate.sure', payload: { 'rake' => { 'src' => 34, 'dest' => 12 } })
    expect(described_class.from_finding(sure).to_params).to eq('source_id' => 34, 'dest_id' => 12, 'autofix' => true)
    relay = FactoryBot.build(:ops_health_finding, check_key: 'badges.relay_category', payload: { 'rake' => { 'src' => 56 } })
    operation = described_class.from_finding(relay)
    expect(operation.to_params).to eq('source_id' => 56, 'autofix' => true)
    expect(operation.file_base).to eq('merge_badges-56-autofix')
    expect(operation.typed_token).to eq('FIX 56')
  end

  it 'suggests a ranks recompute for each meeting with results of the badges' do
    mir = health_add_mir(FactoryBot.create(:meeting, season:), badge: src_badge, swimmer: src_badge.swimmer, team:)
    plan = described_class.new(source_id: src_badge.id, dest_id: dest_badge.id).plan
    meeting_id = mir.meeting_program.meeting_event.meeting_session.meeting_id
    expect(plan.summary['meeting_ids']).to eq([meeting_id])
    expect(described_class.new(source_id: src_badge.id, dest_id: dest_badge.id).follow_ups(plan))
      .to eq([{ 'operation_key' => 'ranks.recompute', 'params' => { 'meeting_id' => meeting_id } }])
  end
end
