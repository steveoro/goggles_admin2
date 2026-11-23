# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Checks::People do
  let(:season) { closed_health_season }
  let(:other_season) { closed_health_season }
  let(:team) { FactoryBot.create(:team, name: 'Alpha Aquatics Bergamo', editable_name: 'Alpha Aquatics Bergamo') }
  let(:male) { GogglesDb::GenderType.male }
  let(:affiliations) { {} }
  let(:categories) { {} }

  def swimmer(last_name, first_name, year)
    FactoryBot.create(:swimmer, last_name:, first_name:, complete_name: "#{last_name} #{first_name}", year_of_birth: year,
                                gender_type: male)
  end

  def badge(swimmer, in_season: season)
    affiliation = affiliations[in_season.id] ||= FactoryBot.create(:team_affiliation, season: in_season, team:)
    category = categories[in_season.id] ||= FactoryBot.create(:category_type, season: in_season)
    FactoryBot.create(:badge, season: in_season, swimmer:, team:, team_affiliation: affiliation, category_type: category)
  end

  def run_check
    described_class.new(season:, entry: health_entry(season, status: :closed)).call
  end

  it 'reports same-name swimmers with a year typo and a team in common, and typo names in the same bucket (warnings)' do
    badged = swimmer('ZZPLUTARCO', 'ANSELMO', 1970)
    badge(badged)
    year_typo = swimmer('ZZPLUTARCO', 'ANSELMO', 1971)
    badge(year_typo, in_season: other_season) # (same team, another season)
    name_typo = swimmer('ZZPLUTARCO', 'ANSELM', 1970)
    badge(name_typo)

    findings = run_check.index_by(&:subject_ids)
    expect(findings.keys).to contain_exactly([badged.id, year_typo.id].sort, [badged.id, name_typo.id].sort)
    expect(findings.values.map(&:severity).uniq).to eq(['warning'])
    expect(findings[[badged.id, year_typo.id].sort].payload).to include('reason' => 'same_name', 'year_gap' => 1)
    similar = findings[[badged.id, name_typo.id].sort]
    expect(similar.payload).to include('reason' => 'similar_name', 'shared_team_ids' => [team.id])
    expect(similar.identity).to eq("swimmers:#{[badged.id, name_typo.id].sort.join(',')}")
  end

  it 'leaves out distant years, same names without a common team and siblings sharing the last name only' do
    badge(swimmer('ZZPLUTARCO', 'BRUNO', 1950))
    badge(swimmer('ZZPLUTARCO', 'BRUNO', 1980), in_season: other_season) # (father and son)
    badge(swimmer('ZZQUERCIA', 'CARLO', 1970))
    swimmer('ZZQUERCIA', 'CARLO', 1971) # (no badge on a common team)
    badge(swimmer('ZZPUPPINATO', 'LISA', 2006))
    badge(swimmer('ZZPUPPINATO', 'GIULIA', 2006)) # (twins)
    expect(run_check).to eq([])
  end

  it 'accepts a swapped-digits year of birth and reads the thresholds from the ops settings' do
    badged = swimmer('ZZPLUTARCO', 'DARIO', 1967)
    badge(badged)
    badge(swimmer('ZZPLUTARCO', 'DARIO', 1976), in_season: other_season)
    badge(swimmer('ZZPLUTARCO', 'ANSELMO', 1970))
    badge(swimmer('ZZPLUTARCO', 'ANSELM', 1970))
    expect(run_check.map { |finding| finding.payload['reason'] }).to contain_exactly('same_name', 'similar_name')

    Ops::Setting.store!(described_class::SIMILARITY_KEY, 0.999)
    expect(run_check.map { |finding| finding.payload['reason'] }).to eq(['same_name'])
  end
end
