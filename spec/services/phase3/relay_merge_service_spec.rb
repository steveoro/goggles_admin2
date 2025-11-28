# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Phase3::RelayMergeService, type: :service do
  describe '#self_enrich!' do
    context 'when swimmers have missing gender but badges have gender in key' do
      let(:main_data) do
        {
          'swimmers' => [
            {
              'key' => '|ANGELINI|Mario|2001',
              'last_name' => 'ANGELINI',
              'first_name' => 'Mario',
              'year_of_birth' => 2001,
              'gender_type_code' => nil, # MISSING
              'complete_name' => 'ANGELINI Mario',
              'swimmer_id' => nil
            }
          ],
          'badges' => [
            # Badge without gender (from mixed relay)
            {
              'swimmer_key' => '|ANGELINI|Mario|2001',
              'team_key' => 'Centro Nuoto Bastia asd',
              'season_id' => 242
            },
            # Badge WITH gender (from individual result)
            {
              'swimmer_key' => 'M|ANGELINI|Mario|2001',
              'team_key' => 'Centro Nuoto Bastia asd',
              'season_id' => 242
            }
          ]
        }
      end

      it 'extracts gender from badge key and updates swimmer' do
        service = described_class.new(main_data)
        service.self_enrich!
        result = service.result

        swimmer = result['swimmers'].first
        expect(swimmer['gender_type_code']).to eq('M')
        expect(swimmer['key']).to eq('M|ANGELINI|Mario|2001')
        expect(service.stats[:swimmers_updated]).to eq(1)
      end
    end

    context 'when multiple badges have conflicting genders' do
      let(:main_data) do
        {
          'swimmers' => [
            {
              'key' => '|ROSSI|Andrea|1990',
              'last_name' => 'ROSSI',
              'first_name' => 'Andrea',
              'year_of_birth' => 1990,
              'gender_type_code' => nil,
              'complete_name' => 'ROSSI Andrea',
              'swimmer_id' => nil
            }
          ],
          'badges' => [
            {
              'swimmer_key' => 'M|ROSSI|Andrea|1990',
              'team_key' => 'Team A',
              'season_id' => 242
            },
            {
              'swimmer_key' => 'F|ROSSI|Andrea|1990',
              'team_key' => 'Team B',
              'season_id' => 242
            }
          ]
        }
      end

      it 'does not update gender and records ambiguous match' do
        service = described_class.new(main_data)
        service.self_enrich!
        result = service.result

        swimmer = result['swimmers'].first
        expect(swimmer['gender_type_code']).to be_nil
        expect(swimmer['key']).to eq('|ROSSI|Andrea|1990')

        ambiguous = service.stats[:partial_matches_ambiguous]
        expect(ambiguous.size).to eq(1)
        expect(ambiguous.first[:issue]).to eq('multiple_genders_in_badges')
        expect(ambiguous.first[:found_genders]).to contain_exactly('M', 'F')
      end
    end
  end

  describe '#merge_from with partial matching' do
    context 'when aux file has swimmer with gender that main file lacks' do
      let(:main_data) do
        {
          'swimmers' => [
            {
              'key' => '|BIANCHI|Maria|1985',
              'last_name' => 'BIANCHI',
              'first_name' => 'Maria',
              'year_of_birth' => 1985,
              'gender_type_code' => nil,
              'complete_name' => 'BIANCHI Maria',
              'swimmer_id' => nil
            }
          ],
          'badges' => []
        }
      end

      let(:aux_data) do
        {
          'swimmers' => [
            {
              'key' => 'F|BIANCHI|Maria|1985',
              'last_name' => 'BIANCHI',
              'first_name' => 'Maria',
              'year_of_birth' => 1985,
              'gender_type_code' => 'F',
              'complete_name' => 'BIANCHI Maria',
              'swimmer_id' => 12_345
            }
          ],
          'badges' => []
        }
      end

      it 'enriches gender via partial key match' do
        service = described_class.new(main_data)
        service.merge_from(aux_data)
        result = service.result

        swimmer = result['swimmers'].first
        expect(swimmer['gender_type_code']).to eq('F')
        expect(swimmer['key']).to eq('F|BIANCHI|Maria|1985')
        expect(service.stats[:swimmers_updated]).to be >= 1
      end
    end
  end
end
