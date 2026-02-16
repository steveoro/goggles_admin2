# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Solvers::SwimmerSolver do
  # Use existing season from test DB (no creation needed)
  let(:season) { GogglesDb::Season.find(242) }

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
      # New format: gender prefix when known, leading pipe when unknown
      expect(keys).to include('M|DOE|JOHN|1970')
      expect(keys).to include('M|ROSSI|Mario|1980')
      expect(data['badges']).to include(include('swimmer_key' => 'M|DOE|JOHN|1970', 'team_key' => 'Team X', 'season_id' => season.id))
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
      # New format: gender prefix from section fin_sesso
      expect(keys).to include('M|Neri|Luca|1990')
      expect(keys).to include('M|VERDI|Paolo|1985')
      # Badge inferred from team
      expect(data['badges']).to include(include('swimmer_key' => 'M|Neri|Luca|1990', 'team_key' => 'Alpha', 'season_id' => season.id))
    end
  end

  describe 'pre-matching pattern (v2.0)' do
    it 'stores swimmer_id when swimmer exists' do
      # Use existing swimmer from test DB
      swimmer = GogglesDb::Swimmer.limit(100).sample

      Dir.mktmpdir do |tmp|
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => ["#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|Team X"]
                         })

        described_class.new(season:).build!(source_path: src, lt_format: 4)

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        # Key now includes gender prefix
        expected_key = "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        swimmer_entry = data['swimmers'].find { |s| s['key'] == expected_key }
        expect(swimmer_entry['swimmer_id']).to eq(swimmer.id)
      end
      # No cleanup needed - using existing DB data
    end

    it 'stores badge_id when badge exists' do # rubocop:disable RSpec/ExampleLength
      # Use existing badge from test DB; create one via FactoryBot if none exist for this season
      badge = GogglesDb::Badge.joins(:team, :swimmer)
                              .where(season_id: season.id)
                              .limit(100)
                              .sample
      unless badge
        cat_type = GogglesDb::CategoryType.where(season_id: season.id).sample ||
                   FactoryBot.create(:category_type, season: season)
        badge = FactoryBot.create(:badge, category_type: cat_type)
      end

      swimmer = badge.swimmer
      team = badge.team

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

        expected_key = "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == expected_key
        end

        expect(badge_entry['badge_id']).to eq(badge.id)
        expect(badge_entry['swimmer_id']).to eq(swimmer.id)
        expect(badge_entry['team_id']).to eq(team.id)
      end
    end

    it 'stores category_type_id on badges when category can be calculated' do # rubocop:disable RSpec/ExampleLength
      swimmer = GogglesDb::Swimmer.first
      team = GogglesDb::Team.first
      meeting_date = '2025-10-15'

      Dir.mktmpdir do |tmp|
        # Create phase1 with meeting date (header_date is at data level, not data.meeting)
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'header_date' => meeting_date
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

        expected_key = "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == expected_key
        end

        expect(badge_entry['category_type_id']).to be_a(Integer)
        expect(badge_entry['category_type_id']).to be > 0
        expect(badge_entry['category_type_code']).to be_a(String)
        # Category codes: M## (Master), U## (Under), MA# (100+)
        expect(badge_entry['category_type_code']).to match(/^(M\d{2}|MA\d|U\d{2})$/)
      end
    end

    it 'stores category_type_id on swimmers when category can be calculated' do
      swimmer = GogglesDb::Swimmer.first
      meeting_date = '2025-10-15'

      Dir.mktmpdir do |tmp|
        # Create phase1 with meeting date (header_date is at data level, not data.meeting)
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'header_date' => meeting_date
                                                       }
                                                     }))

        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}|Team X"
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src,
          lt_format: 4,
          phase1_path: phase1_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        expected_key = "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        swimmer_entry = data['swimmers'].find do |s|
          s['key'] == expected_key
        end

        expect(swimmer_entry['category_type_id']).to be_a(Integer)
        expect(swimmer_entry['category_type_id']).to be > 0
        expect(swimmer_entry['category_type_code']).to be_a(String)
        # Category codes: M## (Master), U## (Under), MA# (100+)
        expect(swimmer_entry['category_type_code']).to match(/^(M\d{2}|MA\d|U\d{2})$/)
      end
    end

    it 'infers gender from high-confidence match and flags as gender_guessed' do
      # Use existing swimmer from test DB - need one with high match potential
      swimmer = GogglesDb::Swimmer.limit(100).sample
      meeting_date = '2025-10-15'

      Dir.mktmpdir do |tmp|
        # Create phase1 with meeting date
        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'header_date' => meeting_date
                                                       }
                                                     }))

        # Simulate swimmer data WITHOUT gender - exact name match should give >=90% confidence
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             { 'last_name' => swimmer.last_name, 'first_name' => swimmer.first_name, 'year_of_birth' => swimmer.year_of_birth, 'team' => 'Team X' }
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src,
          lt_format: 4,
          phase1_path: phase1_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']

        # Find the swimmer entry - key may have gender prefix if match was high-confidence
        swimmer_entry = data['swimmers'].find do |s|
          s['last_name'] == swimmer.last_name && s['first_name'] == swimmer.first_name
        end

        expect(swimmer_entry).to be_present

        # If high-confidence match found, gender should be guessed and flagged
        if swimmer_entry['swimmer_id'].present?
          expect(swimmer_entry['gender_guessed']).to be(true)
          expect(swimmer_entry['gender_type_code']).to eq(swimmer.gender_type.code)
          # Key should include gender prefix
          expect(swimmer_entry['key']).to start_with("#{swimmer.gender_type.code}|")
          # Match percentage should be below 90 to appear in "needs review" filter
          expect(swimmer_entry['match_percentage']).to eq(89.9)
        else
          # No high-confidence match found - stays unmatched
          expect(swimmer_entry['gender_guessed']).to be(false)
          expect(swimmer_entry['gender_type_code']).to be_blank
        end
      end
    end

    it 'sets similar_on_team when a similar swimmer exists on the same team' do # rubocop:disable RSpec/ExampleLength
      # Use existing badge from test DB; create one via FactoryBot if none exist for this season
      badge = GogglesDb::Badge.joins(:team, :swimmer)
                              .where(season_id: season.id)
                              .limit(100)
                              .sample
      unless badge
        cat_type = GogglesDb::CategoryType.where(season_id: season.id).sample ||
                   FactoryBot.create(:category_type, season: season)
        badge = FactoryBot.create(:badge, category_type: cat_type)
      end

      swimmer = badge.swimmer
      team = badge.team

      # Create a slightly misspelled version of the swimmer name
      misspelled_last = swimmer.last_name.dup
      misspelled_last[0] = misspelled_last[0] == 'A' ? 'B' : 'A' # Change first letter

      Dir.mktmpdir do |tmp|
        # Create phase2 with team_id so cross-ref can resolve the team
        phase2_path = File.join(tmp, 'meeting-l4-phase2.json')
        File.write(phase2_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => {
                                                         'teams' => [{ 'key' => team.name, 'team_id' => team.id }]
                                                       }
                                                     }))

        phase1_path = File.join(tmp, 'meeting-l4-phase1.json')
        File.write(phase1_path, JSON.pretty_generate({
                                                       '_meta' => {},
                                                       'data' => { 'header_date' => '2025-10-15' }
                                                     }))

        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => [
                             "#{swimmer.gender_type.code}|#{misspelled_last}|#{swimmer.first_name}|#{swimmer.year_of_birth}|#{team.name}"
                           ]
                         })

        described_class.new(season:).build!(
          source_path: src, lt_format: 4,
          phase1_path: phase1_path, phase2_path: phase2_path
        )

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']
        expected_key = "#{swimmer.gender_type.code}|#{misspelled_last}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        swimmer_entry = data['swimmers'].find { |s| s['key'] == expected_key }

        expect(swimmer_entry).to be_present
        # The similar_on_team flag should be set (the real swimmer is on the same team)
        expect(swimmer_entry['similar_on_team']).to be(true)
        expect(swimmer_entry['team_cross_ref']).to be_present
        expect(swimmer_entry['team_cross_ref']['candidates']).to be_an(Array)
        expect(swimmer_entry['team_cross_ref']['candidates'].map { |c| c['id'] }).to include(swimmer.id)
      end
    end

    it 'does not set similar_on_team when no team is available' do
      Dir.mktmpdir do |tmp|
        src = write_json(tmp, 'meeting-l4.json', {
                           'layoutType' => 4,
                           'swimmers' => ['M|UNKNOWN|PERSON|1985']
                         })

        described_class.new(season:).build!(source_path: src, lt_format: 4)

        phase3 = default_phase3_path(src)
        data = JSON.parse(File.read(phase3))['data']
        swimmer_entry = data['swimmers'].find { |s| s['key'] == 'M|UNKNOWN|PERSON|1985' }

        expect(swimmer_entry).to be_present
        expect(swimmer_entry['similar_on_team']).to be(false)
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

        expected_key = "#{swimmer.gender_type.code}|#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}"
        badge_entry = data['badges'].find do |b|
          b['swimmer_key'] == expected_key
        end

        # Should be nil (new badge to create)
        expect(badge_entry['badge_id']).to be_nil
      end
    end
  end
end
