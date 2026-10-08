# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonDefaults do
  describe '.default_season' do
    it 'returns the latest-defined MASFIN season' do
      expected = GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin)
      expect(described_class.default_season).to eq(expected)
      expect(described_class.default_season.season_type.code).to eq('MASFIN')
    end

    it 'prefers the MASFIN season with the latest begin_date' do
      older = GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin)
      newer = FactoryBot.create(:season,
                                season_type_id: GogglesDb::SeasonType.mas_fin.id,
                                begin_date: older.begin_date + 1.year,
                                end_date: older.end_date + 1.year)

      expect(described_class.default_season).to eq(newer)
      expect(described_class.default_season_id).to eq(newer.id)
    end

    it 'returns nil when no MASFIN season is defined' do
      allow(GogglesDb::Season).to receive(:last_season_by_type).and_return(nil)

      expect(described_class.default_season).to be_nil
      expect(described_class.default_season_id).to be_nil
    end
  end
end
