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
end
