# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::BadgeSwimmerFix do
  include RakeParity::Fixtures

  before(:each) { hide_leftover_seasons! }

  let(:badge) { GogglesDb::Badge.find(RakeParity::Fixtures::BADGE_B) }
  let(:new_swimmer) { GogglesDb::Swimmer.find(142) }

  it "plans exactly the strategy's SQL without writing, its report as console" do
    fixer = Merge::SwimmerInBadge.new(badges: [badge], new_swimmer:)
    report = Maintenance::OutputCapture.capture { fixer.display_report }.last
    fixer.prepare
    operation = described_class.new(badge_ids: badge.id.to_s, swimmer_id: new_swimmer.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(fixer.sql_log)
    expect(operation.captured_output).to eq(report)
    expect(operation.file_base).to eq("fix_swimmer_in_badge-#{badge.id}")
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new.plan).to be_blocked
    expect(described_class.new(badge_ids: badge.id.to_s, swimmer_id: 0).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: 0)])
  end
end
