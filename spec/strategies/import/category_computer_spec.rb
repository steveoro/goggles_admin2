# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::CategoryComputer do
  let(:season_type_id) { GogglesDb::SeasonType::MAS_FIN_ID }
  let(:season) do
    FactoryBot.create(:season, season_type_id:, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30))
  end
  let(:m20) { FactoryBot.create(:category_type, season:, code: 'M20', age_begin: 20, age_end: 24) }
  let(:m55) { FactoryBot.create(:category_type, season:, code: 'M55', age_begin: 55, age_end: 59) }
  let(:m60) { FactoryBot.create(:category_type, season:, code: 'M60', age_begin: 60, age_end: 64) }
  let(:younger_relay) { FactoryBot.create(:category_type, season:, code: '200-239', age_begin: 200, age_end: 239, relay: true) }
  let(:older_relay) { FactoryBot.create(:category_type, season:, code: '240-279', age_begin: 240, age_end: 279, relay: true) }
  let(:categories_cache) { PdfResults::CategoriesCache.new(season, category_types: [m20, m55, m60, younger_relay, older_relay]) }

  def category_for(year, meeting_date)
    described_class.compute_category(
      year_of_birth: year, gender_code: 'M', meeting_date:, season:, categories_cache:
    )
  end

  it 'uses the second year of the FIN Master season for autumn individual results' do
    expect(category_for(1967, '2026-11-22')).to eq([m60.id, 'M60'])
    expect(category_for(2007, '2026-11-22')).to eq([m20.id, 'M20'])
  end

  it 'keeps the same individual category in the second calendar year of the season' do
    expect(category_for(1967, '2027-06-20')).to eq([m60.id, 'M60'])
  end

  context 'with a non-FIN Master season' do
    let(:season_type_id) { GogglesDb::SeasonType::MAS_CSI_ID }

    it 'retains the meeting-year age calculation' do
      expect(category_for(1967, '2026-11-22')).to eq([m55.id, 'M55'])
    end
  end

  it 'keeps relay age sums based on the year of the race' do
    swimmer_keys = %w[ROSSI VERDI BIANCHI NERI].map { |name| "M|#{name}|MARIO|1967|TEAM" }

    result = described_class.compute_relay_category(
      swimmer_keys:, meeting_date: '2026-11-22', season:, categories_cache:
    )

    expect(result).to eq([younger_relay.id, '200-239'])
  end
end
