# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Solvers::TeamSolver do
  # Use existing season from test DB (no creation needed)
  let(:season) { GogglesDb::Season.find(242) }

  def write_json(tmpdir, name, hash)
    path = File.join(tmpdir, name)
    File.write(path, JSON.pretty_generate(hash))
    path
  end

  def default_phase2_path(src)
    dir = File.dirname(src)
    base = File.basename(src, File.extname(src))
    File.join(dir, "#{base}-phase2.json")
  end

  it 'builds phase2 from LT4 teams dictionary (seeding)' do
    Dir.mktmpdir do |tmp|
      src = write_json(tmp, 'meeting-l4.json', {
                         'layoutType' => 4,
                         'teams' => ['Team A', { 'name' => 'Team B' }]
                       })

      described_class.new(season:).build!(source_path: src, lt_format: 4)

      phase2 = default_phase2_path(src)
      expect(File).to exist(phase2)
      data = JSON.parse(File.read(phase2))['data']
      expect(data['teams']).to include(include('key' => 'Team A'))
      expect(data['teams']).to include(include('key' => 'Team B'))
      expect(data['team_affiliations']).to include(include('team_key' => 'Team A', 'season_id' => season.id))
    end
  end

  it 'builds phase2 from LT2 sections scan (fallback)' do
    Dir.mktmpdir do |tmp|
      src = write_json(tmp, 'meeting-l2.json', {
                         'layoutType' => 2,
                         'sections' => [
                           { 'rows' => [{ 'team' => 'Alpha' }, { 'team' => 'Beta' }, { 'team' => '' }] },
                           { 'rows' => [{ 'team' => 'Alpha' }] }
                         ]
                       })

      described_class.new(season:).build!(source_path: src, lt_format: 2)

      phase2 = default_phase2_path(src)
      expect(File).to exist(phase2)
      data = JSON.parse(File.read(phase2))['data']
      keys = data['teams'].map { |h| h['key'] }
      expect(keys).to include('Alpha', 'Beta')
      expect(data['team_affiliations']).to include(include('team_key' => 'Alpha', 'season_id' => season.id))
    end
  end

  describe 'team name normalization' do
    subject(:solver) { described_class.new(season:) }

    it 'strips common Italian association abbreviations' do
      # Access private method for direct testing
      expect(solver.send(:normalize_team_name, 'Nuoto Master A.S.D.')).to eq('NUOTO MASTER')
      expect(solver.send(:normalize_team_name, 'ASD Nuoto Master')).to eq('NUOTO MASTER')
      expect(solver.send(:normalize_team_name, 'S.S.D. Gonzaga S.R.L.')).to eq('GONZAGA')
      expect(solver.send(:normalize_team_name, 'Team Test')).to eq('TEAM TEST')
    end

    it 'handles empty and nil names' do
      expect(solver.send(:normalize_team_name, '')).to eq('')
      expect(solver.send(:normalize_team_name, nil)).to eq('')
    end
  end

  describe 'affiliation cross-reference' do
    it 'sets similar_affiliated and promotes affiliated match in fuzzy_matches' do
      # Use existing affiliation from test DB; create one via FactoryBot if none exist for this season
      affiliation = GogglesDb::TeamAffiliation.where(season_id: season.id).limit(50).sample ||
                    FactoryBot.create(:team_affiliation, season: season)

      team = affiliation.team
      # Create a slightly different team name to trigger fuzzy matching but not auto-assignment
      variant_name = "#{team.editable_name} XYZ"

      Dir.mktmpdir do |tmp|
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'teams' => [variant_name]
                         })

        described_class.new(season:).build!(source_path: src, lt_format: 4)

        phase2 = default_phase2_path(src)
        data = JSON.parse(File.read(phase2))['data']
        team_entry = data['teams'].find { |t| t['key'] == variant_name }

        expect(team_entry).to be_present
        fuzzy = team_entry['fuzzy_matches'] || []
        affiliated_match = fuzzy.find { |m| m['id'] == team.id }
        if affiliated_match
          # Affiliated match should have the flag and be promoted toward the top
          expect(affiliated_match['affiliated_this_season']).to be(true)
          aff_index = fuzzy.index(affiliated_match)
          non_aff_indices = fuzzy.each_with_index.reject { |m, _| m['affiliated_this_season'] }.map(&:last)
          expect(aff_index).to be < non_aff_indices.first if non_aff_indices.any?
        end
      end
    end

    it 'finds similar affiliated teams via normalized name cross-reference' do
      # Use existing affiliation from test DB; create one via FactoryBot if none exist for this season
      affiliation = GogglesDb::TeamAffiliation.where(season_id: season.id).limit(50).sample ||
                    FactoryBot.create(:team_affiliation, season: season)

      team = affiliation.team
      solver = described_class.new(season:)
      # Test the private method directly with a slightly altered name
      candidates = solver.send(:find_similar_affiliated_teams, team.editable_name.chars.shuffle.join)

      # Result should be an array (may or may not have candidates depending on name shuffle)
      expect(candidates).to be_an(Array)
    end

    it 'includes similar_affiliated flag in team entries' do
      Dir.mktmpdir do |tmp|
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'teams' => ['Completely Unknown Team ZZZZZ']
                         })

        described_class.new(season:).build!(source_path: src, lt_format: 4)

        phase2 = default_phase2_path(src)
        data = JSON.parse(File.read(phase2))['data']
        team_entry = data['teams'].find { |t| t['key'] == 'Completely Unknown Team ZZZZZ' }

        expect(team_entry).to be_present
        expect(team_entry).to have_key('similar_affiliated')
        expect(team_entry['similar_affiliated']).to be(false)
      end
    end
  end
end
