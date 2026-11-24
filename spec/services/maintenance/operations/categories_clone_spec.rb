# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::CategoriesClone do
  it "plans exactly the strategy's SQL without writing, its log as console" do
    cloner = Import::CategoryCloner.new(src_season: GogglesDb::Season.find(252), dest_season: GogglesDb::Season.find(262), remove_codes: %w[M25])
    cloner.prepare
    operation = described_class.new(src_season_id: 252, dest_season_id: 262, remove_codes: ' M25 ')
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(cloner.sql_log)
    expect(plan.console).to eq(cloner.log.join("\r\n"))
    expect(plan.season_id).to eq(262)
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.typed_token).to eq('CLONE 252 INTO 262')
    expect(described_class.new(src_season_id: 252, dest_season_id: 262).confirmation_for(plan)).to eq(:confirm)
    expect(described_class).to be_checklist_only
  end

  it 'blocks the plan on the cloner errors and on unknown seasons' do
    expect(described_class.new(src_season_id: 0, dest_season_id: 262).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Season', id: 0)])
  end
end
