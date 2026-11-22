# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::Badge do
  let(:season) do
    FactoryBot.create(
      :season, season_type_id: GogglesDb::SeasonType::MAS_FIN_ID,
               begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)
    )
  end
  let(:m55) { FactoryBot.create(:category_type, season:, code: 'M55', age_begin: 55, age_end: 59) }
  let(:m60) { FactoryBot.create(:category_type, season:, code: 'M60', age_begin: 60, age_end: 64) }
  let(:categories_cache) { PdfResults::CategoriesCache.new(season, category_types: [m55, m60]) }
  let(:swimmer) { FactoryBot.create(:swimmer, year_of_birth: 1967) }
  let(:swimmer_key) { "M|#{swimmer.last_name}|#{swimmer.first_name}|1967|TEAM" }
  let(:header_date) { Date.new(2026, 11, 22) }
  let(:committer) do
    stats = {}
    sql_log = []
    swimmer_committer = Import::Committers::Swimmer.new(stats:, logger: nil, sql_log:)
    team_committer = Import::Committers::Team.new(stats:, logger: nil, sql_log:)
    team_affiliation_committer = Import::Committers::TeamAffiliation.new(
      team_committer:, season_id: season.id, stats:, logger: nil, sql_log:
    )
    swimmer_committer.store_id(swimmer_key, swimmer.id)
    described_class.new(
      swimmer_committer:, team_committer:, team_affiliation_committer:, categories_cache:,
      season_id: season.id, meeting: GogglesDb::Meeting.new(header_date:),
      stats:, logger: nil, sql_log:
    )
  end

  it 'uses the FIN Master season age when resolving a missing badge category' do
    expect(committer.resolve_category_type_id(swimmer_key)).to eq(m60.id)
  end

  context 'when the age cannot be computed' do
    let(:header_date) { nil }

    it 'raises a descriptive error' do
      expect { committer.resolve_category_type_id(swimmer_key) }
        .to raise_error(StandardError, /Unable to compute category age/)
    end
  end
end
