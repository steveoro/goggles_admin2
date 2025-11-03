# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Solvers::SwimmerSolver do
  let(:season) do
    GogglesDb::Season.first || GogglesDb::Season.create!(id: 212, description: 'Test Season', begin_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 12, 31))
  end

  def write_json(tmpdir, name, hash)
    path = File.join(tmpdir, name)
    File.write(path, JSON.pretty_generate(hash))
    path
  end

  def default_phase3_path(src)
    dir = File.dirname(src)
    base = File.basename(src, File.extname(src))
    File.join(dir, "#{base}-phase3.json")
  end

  it 'builds phase3 from LT4 swimmers dictionary (seeding)' do
    Dir.mktmpdir do |tmp|
      src = write_json(tmp, 'meeting-l4.json', {
                         'layoutType' => 4,
                         'swimmers' => [
                           'M|DOE|JOHN|1970|Team X',
                           { 'last_name' => 'ROSSI', 'first_name' => 'Mario', 'year_of_birth' => 1980, 'gender' => 'M', 'team' => 'Team Y' }
                         ]
                       })

      described_class.new(season:).build!(source_path: src, lt_format: 4)

      phase3 = default_phase3_path(src)
      expect(File).to exist(phase3)
      data = JSON.parse(File.read(phase3))['data']
      keys = data['swimmers'].map { |h| h['key'] }
      expect(keys).to include('DOE|JOHN|1970')
      expect(keys).to include('ROSSI|Mario|1980')
      expect(data['badges']).to include(include('swimmer_key' => 'DOE|JOHN|1970', 'team_key' => 'Team X', 'season_id' => season.id))
    end
  end

  it 'builds phase3 from LT2 sections scan (fallback)' do
    Dir.mktmpdir do |tmp|
      src = write_json(tmp, 'meeting-l2.json', {
                         'layoutType' => 2,
                         'sections' => [
                           { 'fin_sesso' => 'M', 'rows' => [
                             { 'last_name' => 'Neri', 'first_name' => 'Luca', 'year_of_birth' => 1990, 'team' => 'Alpha' },
                             { 'swimmer' => 'VERDI Paolo', 'anno' => 1985, 'team' => 'Beta' },
                             { 'relay' => true, 'team' => 'Alpha' }
                           ] }
                         ]
                       })

      described_class.new(season:).build!(source_path: src, lt_format: 2)

      phase3 = default_phase3_path(src)
      expect(File).to exist(phase3)
      data = JSON.parse(File.read(phase3))['data']
      keys = data['swimmers'].map { |h| h['key'] }
      expect(keys).to include('Neri|Luca|1990')
      expect(keys).to include('VERDI|Paolo|1985')
      # Badge inferred from team
      expect(data['badges']).to include(include('swimmer_key' => 'Neri|Luca|1990', 'team_key' => 'Alpha', 'season_id' => season.id))
    end
  end

  describe 'pre-matching pattern (v2.0)' do
    it 'stores swimmer_id when swimmer exists' do
      # Create a known swimmer
      swimmer = GogglesDb::Swimmer.create!(
        last_name: 'TEST',
        first_name: 'Swimmer',
        year_of_birth: 1975,
        gender_type: GogglesDb::GenderType.male
      )

      Dir.mktmpdir do |tmp|
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => ["M|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|Team X"]
                         })

        described_class.new(season:).build!(source_path: src, lt_format: 4)

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        swimmer_entry = data['swimmers'].find { |s| s['key'] == "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}" }
        expect(swimmer_entry['swimmer_id']).to eq(swimmer.id)
      end

      swimmer.destroy # Cleanup
    end

    it 'stores badge_id when badge exists' do
      # Create test data
      swimmer = GogglesDb::Swimmer.first
      team = GogglesDb::Team.first
      badge = GogglesDb::Badge.create!(
        swimmer: swimmer,
        team: team,
        season: season,
        category_type: GogglesDb::CategoryType.first
      )

      Dir.mktmpdir do |tmp|
        # Create phase2 with team_id
        phase2_path = File.join(tmp, 'meeting-l4-phase2.json')
        File.write(phase2_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'teams' => [{ 'key' => team.name, 'team_id' => team.id }]
                                                       }
                                                     }))

        # Create phase1 with meeting date for category calculation
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'meeting' => { 'header_date' => '2025-10-15' }
                                                       }
                                                     }))

        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|#{team.name}"
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src,
          lt_format: 4,
          phase1_path: phase1_path,
          phase2_path: phase2_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        end

        expect(badge_entry['badge_id']).to eq(badge.id)
        expect(badge_entry['swimmer_id']).to eq(swimmer.id)
        expect(badge_entry['team_id']).to eq(team.id)
      end

      badge.destroy # Cleanup
    end

    it 'stores category_type_id when category can be calculated' do
      swimmer = GogglesDb::Swimmer.first
      team = GogglesDb::Team.first
      meeting_date = '2025-10-15'

      Dir.mktmpdir do |tmp|
        # Create phase1 with meeting date
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'meeting' => { 'header_date' => meeting_date }
                                                       }
                                                     }))

        # Create phase2 with team_id
        phase2_path = File.join(tmp, 'meeting-l4-phase2.json')
        File.write(phase2_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'teams' => [{ 'key' => team.name, 'team_id' => team.id }]
                                                       }
                                                     }))

        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|#{team.name}"
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src,
          lt_format: 4,
          phase1_path: phase1_path,
          phase2_path: phase2_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        end

        expect(badge_entry['category_type_id']).to be_a(Integer)
        expect(badge_entry['category_type_id']).to be > 0
      end
    end

    it 'stores nil badge_id when badge does not exist (new badge)' do
      # Use swimmer that definitely doesn't have a badge for this season
      swimmer = GogglesDb::Swimmer.first
      team = GogglesDb::Team.last # Different team to avoid conflicts

      Dir.mktmpdir do |tmp|
        # Create phase2 with team_id
        phase2_path = File.join(tmp, 'meeting-l4-phase2.json')
        File.write(phase2_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'teams' => [{ 'key' => team.name, 'team_id' => team.id }]
                                                       }
                                                     }))

        # Create phase1 with meeting date
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'meeting' => { 'header_date' => '2025-10-15' }
                                                       }
                                                     }))

        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|#{team.name}"
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src,
          lt_format: 4,
          phase1_path: phase1_path,
          phase2_path: phase2_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        end

        # Should be nil (new badge to create)
        expect(badge_entry['badge_id']).to be_nil
      end
    end
  end
end
