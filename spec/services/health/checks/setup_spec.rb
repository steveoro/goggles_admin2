# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Checks::Setup do
  let(:season) { closed_health_season }

  def run_check(status)
    described_class.new(season:, entry: health_entry(season, status:)).call
  end

  it 'reports a season without categories nor standard timings: info when closed, error when current or upcoming' do
    finding = run_check(:closed).sole
    expect(finding).to have_attributes(check_key: 'season.setup', severity: 'info', identity: "season:#{season.id}")
    expect(finding.payload).to include('category_types' => 0, 'standard_timings' => 0,
                                       'doc' => 'docs/HOWTO_prepare_new_season_at_championship_start.md')
    expect(run_check(:current).sole.severity).to eq('error')
    expect(run_check(:upcoming).sole.severity).to eq('error')
  end

  it 'reports nothing when the season has categories and standard timings' do
    category = FactoryBot.create(:category_type, season:)
    FactoryBot.create(:standard_timing, season:, category_type: category)
    expect(run_check(:current)).to eq([])
  end
end
