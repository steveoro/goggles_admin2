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
end
