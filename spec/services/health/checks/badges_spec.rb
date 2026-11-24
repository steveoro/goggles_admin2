# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Checks::Badges do
  let(:season) { closed_health_season }
  let(:cat_a) { FactoryBot.create(:category_type, season:, code: 'M40', age_begin: 40, age_end: 44) }
  let(:cat_b) { FactoryBot.create(:category_type, season:, code: 'M45', age_begin: 45, age_end: 49) }
  let(:relay_cat) { FactoryBot.create(:category_type, season:, code: '160-199', age_begin: 160, age_end: 199, relay: true) }
  let(:alpha) { team('Alpha Aquatics Bergamo') }
  let(:zeta) { team('Zeta Polisportiva Cagliari') }
  let(:rossi) { team('Nuoto Club Rossi Firenze') }
  let(:rosi) { team('Nuoto Club Rosi Firenze') }
  let(:affiliations) { {} }

  def team(name)
    FactoryBot.create(:team, name:, editable_name: name)
  end

  def affiliation(team)
    affiliations[team.id] ||= FactoryBot.create(:team_affiliation, season:, team:)
  end

  def badge(swimmer, team, category)
    FactoryBot.create(:badge, season:, swimmer:, team:, team_affiliation: affiliation(team), category_type: category)
  end

  def run_check
    described_class.new(season:, entry: health_entry(season, status: :closed)).call
  end

  context 'with duplicate, similar and relay badges (one BadgeSeasonChecker run)' do
    let(:same_team) { FactoryBot.create(:swimmer) }
    let(:similar) { FactoryBot.create(:swimmer) }
    let(:shared) { FactoryBot.create(:swimmer) }
    let!(:sure_badges) { [badge(same_team, alpha, cat_a), badge(same_team, alpha, cat_b)] }
    let!(:possible_badges) { [badge(similar, rossi, cat_a), badge(similar, rosi, cat_a)] }
    let!(:shared_badges) { [badge(shared, alpha, cat_a), badge(shared, zeta, cat_a)] }
    let!(:relay) { badge(FactoryBot.create(:swimmer), alpha, relay_cat) }
    let(:findings) { run_check }
    let(:by_key) { findings.group_by(&:check_key) }

    before(:each) do
      meeting = FactoryBot.create(:meeting, season:)
      shared_badges.each { |shared_badge| health_add_mir(meeting, badge: shared_badge) }
    end

    it 'reports the sure merges (same team; teams sharing a meeting) as errors, with the merge:badge arguments' do
      sure = by_key['badges.duplicate.sure'].index_by(&:subject_id)
      ids = sure_badges.map(&:id).sort
      expect(sure.keys).to contain_exactly(same_team.id, shared.id)
      expect(sure[same_team.id]).to have_attributes(severity: 'error', subject_ids: ids, identity: "swimmer:#{same_team.id}|badges:#{ids.join(',')}")
      expect(sure[same_team.id].payload['rake']).to eq('src' => ids.second, 'dest' => ids.first)
      expect(sure[same_team.id].payload).to include('same_team' => true, 'swimmer_name' => same_team.complete_name)
      expect(sure[shared.id].subject_ids).to eq(shared_badges.map(&:id).sort)
    end

    it 'reports the possible merges and the possible team duplicates (similar names) as warnings' do
      expect(by_key['badges.duplicate.possible'].map(&:subject_id)).to eq([similar.id])
      expect(by_key['badges.duplicate.possible'].first.subject_ids).to eq(possible_badges.map(&:id).sort)
      teams = by_key['teams.possible_duplicates']
      team_ids = [rossi.id, rosi.id].sort
      expect(teams.map(&:identity)).to eq(["teams:#{team_ids.join(',')}"])
      expect(Health::Registry.fetch('teams.possible_duplicates').rake_command(teams.first.payload['rake']))
        .to eq("bin/rails check:team src=#{team_ids.last} dest=#{team_ids.first}")
    end

    it 'reports the relay-category badges, with stable identities across runs' do
      expect(by_key['badges.relay_category'].map(&:subject_id)).to eq([relay.id])
      expect(by_key['badges.relay_category'].first.payload).to include('relay_only' => true, 'category_code' => '160-199')
      expect(run_check.map(&:identity)).to match_array(findings.map(&:identity))
    end
  end

  it 'returns no finding for a season without duplicates (the checker analysis runs without its text log)' do
    badge(FactoryBot.create(:swimmer), alpha, cat_a)
    expect(described_class::QuietChecker).to be < Merge::BadgeSeasonChecker
    expect(run_check).to eq([])
  end
end
