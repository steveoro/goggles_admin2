# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::TeamAffiliation do
  let(:stats) do
    {
      affiliations_created: 0,
      affiliations_updated: 0,
      affiliation_links_auto_fixed: 0,
      errors: []
    }
  end
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/team_affiliation_committer_test.log') }
  let(:sql_log) { [] }
  let(:season) { FactoryBot.create(:season) }

  let(:team_committer) do
    Import::Committers::Team.new(stats: { teams_created: 0, teams_updated: 0, errors: [] }, logger:, sql_log: [])
  end
  let(:committer) do
    described_class.new(
      stats:,
      logger:,
      sql_log:,
      team_committer:,
      season_id: season.id
    )
  end

  describe '#resolve_id' do
    it 'resolves by canonical team_id+season_id links even when team_key is nil' do
      team = FactoryBot.create(:team)
      affiliation = FactoryBot.create(:team_affiliation, team:, season:)

      resolved = committer.resolve_id(nil, team_id: team.id, season_id: season.id)

      expect(resolved).to eq(affiliation.id)
    end
  end

  describe '#commit' do
    it 'treats existing DB affiliation row as canonical when incoming id is present but links are blank' do
      team = FactoryBot.create(:team)
      affiliation = FactoryBot.create(:team_affiliation, team:, season:)
      team_committer.store_id(team.name, team.id)

      committed_id = committer.commit(
        {
          'team_key' => team.name,
          'team_id' => nil,
          'season_id' => nil,
          'team_affiliation_id' => affiliation.id
        }
      )

      expect(committed_id).to eq(affiliation.id)
      expect(committer.resolve_id(team.name, team_id: team.id, season_id: season.id)).to eq(affiliation.id)
    end

    it 're-resolves by team_id+season_id when incoming team_affiliation_id is stale' do
      team = FactoryBot.create(:team)
      affiliation = FactoryBot.create(:team_affiliation, team:, season:)
      team_committer.store_id(team.name, team.id)

      committed_id = committer.commit(
        {
          'team_key' => team.name,
          'team_id' => team.id,
          'season_id' => season.id,
          'team_affiliation_id' => 9_999_999
        }
      )

      expect(committed_id).to eq(affiliation.id)
      expect(stats[:affiliation_links_auto_fixed]).to be >= 1
    end
  end
end
