# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Adapters::Layout4To2 do
  describe '.normalize' do
    let(:header) do
      {
        'meetingName' => 'Sample Meeting',
        'meetingURL' => 'http://example.test/meeting',
        'dates' => '2025-06-24,2025-06-25',
        'place' => 'Riccione',
        'seasonId' => '242'
      }
    end

    context 'with individual event including laps' do
      let(:lt4_hash) do
        header.merge(
          'layoutType' => 4,
          'events' => [
            {
              'eventCode' => '800SL',
              'eventGender' => 'F',
              'eventLength' => '800',
              'eventStroke' => 'SL',
              'eventDescription' => '800 m Stile Libero',
              'relay' => false,
              'results' => [
                {
                  'ranking' => '1',
                  'swimmer' => 'F|DOE|Jane|1970|Example Team',
                  'team' => 'Example Team',
                  'timing' => "11'00.51",
                  'category' => 'M55',
                  'laps' => [
                    { 'distance' => '50m', 'timing' => '39.62', 'delta' => '39.62', 'position' => '8' },
                    { 'distance' => '100m', 'timing' => "1'22.08", 'delta' => '42.46', 'position' => '8' }
                  ]
                }
              ]
            }
          ]
        )
      end

      it 'produces LT2-like structure with inline lapXX and deltaXX keys' do # rubocop:disable RSpec/MultipleExpectations
        out = described_class.normalize(data_hash: lt4_hash)
        expect(out['layoutType']).to eq(2)
        expect(out['sections']).to be_an(Array)
        expect(out['sections'].size).to eq(1) # split by category -> only M55 present
        section = out['sections'].first
        expect(section['fin_sesso']).to eq('F')
        expect(section['fin_sigla_categoria']).to eq('M55')
        row = section['rows'].first
        expect(row['name']).to eq('DOE Jane')
        expect(row['team']).to eq('Example Team')
        expect(row['lap50']).to eq('39.62')
        expect(row['delta50']).to eq('39.62')
        expect(row['lap100']).to eq("1'22.08")
        expect(row['delta100']).to eq('42.46')
        expect(row['laps']).to be_an(Array)
        expect(row['laps'].size).to eq(2)
      end
    end

    context 'with relay event and category normalization' do
      let(:relay_lt4_hash) do
        header.merge(
          'layoutType' => 4,
          'events' => [
            {
              'eventCode' => '4x50SL',
              'eventGender' => 'X',
              'eventLength' => '4x50',
              'eventStroke' => 'SL',
              'eventDescription' => '4x50 m Stile Libero',
              'relay' => true,
              'results' => [
                {
                  'ranking' => '1',
                  'team' => 'Mixed Team',
                  'timing' => '1\'40.00',
                  'category' => 'U80',
                  'laps' => [
                    { 'distance' => '50m',  'timing' => '25.00', 'delta' => '25.00', 'swimmer' => 'F|ABE|Ann|1980|Mixed Team' },
                    { 'distance' => '100m', 'timing' => '50.00', 'delta' => '25.00', 'swimmer' => 'M|BEN|Bob|1979|Mixed Team' },
                    { 'distance' => '150m', 'timing' => '75.00', 'delta' => '25.00', 'swimmer' => 'F|CAL|Car|1981|Mixed Team' },
                    { 'distance' => '200m', 'timing' => '1\'40.00', 'delta' => '25.00', 'swimmer' => 'M|DAN|Dan|1978|Mixed Team' }
                  ]
                },
                {
                  'ranking' => '2',
                  'team' => 'Senior Team',
                  'timing' => '1\'50.00',
                  'category' => 'M160',
                  'laps' => []
                }
              ]
            }
          ]
        )
      end

      it 'normalizes relay category and emits inline lapXX/deltaXX keys with swimmers' do # rubocop:disable RSpec/MultipleExpectations
        out = described_class.normalize(data_hash: relay_lt4_hash)
        expect(out['layoutType']).to eq(2)
        expect(out['sections'].size).to eq(2)
        cats = out['sections'].map { |s| s['fin_sigla_categoria'] }
        expect(cats).to contain_exactly('60-79', '160-199')

        mixed_section = out['sections'].find { |s| s['fin_sigla_categoria'] == '60-79' }
        row = mixed_section['rows'].first
        # Inline timing keys
        expect(row['lap50']).to eq('25.00')
        expect(row['delta50']).to eq('25.00')
        expect(row['lap200']).to eq("1'40.00")
        # Swimmer expansion
        expect(row['swimmer1']).to eq('ABE Ann')
        expect(row['swimmer2']).to eq('BEN Bob')
        expect(row['swimmer3']).to eq('CAL Car')
        expect(row['swimmer4']).to eq('DAN Dan')
        # Laps array preserved
        expect(row['laps']).to be_an(Array)
        expect(row['laps'].size).to eq(4)
      end
    end

    context 'with 50m individual event and empty laps' do
      let(:ind_50m_hash) do
        header.merge(
          'layoutType' => 4,
          'events' => [
            {
              'eventCode' => '50SL',
              'eventGender' => 'M',
              'eventLength' => '50',
              'eventStroke' => 'SL',
              'eventDescription' => '50 m Stile Libero',
              'relay' => false,
              'results' => [
                {
                  'ranking' => '3',
                  'swimmer' => 'M|SMITH|John|1985|Example Team',
                  'team' => 'Example Team',
                  'timing' => '25.45',
                  'category' => 'M35',
                  'laps' => []
                }
              ]
            }
          ]
        )
      end

      it 'does not emit inline lapXX/deltaXX keys and preserves empty laps' do
        out = described_class.normalize(data_hash: ind_50m_hash)
        section = out['sections'].first
        row = section['rows'].first
        expect(row['laps']).to eq([])
        expect(row.keys.grep(/^lap\d+/)).to be_empty
        expect(row.keys.grep(/^delta\d+/)).to be_empty
      end
    end

    context 'with relay having unknown gender swimmer keys and blank category' do
      let(:relay_unknown_hash) do
        header.merge(
          'layoutType' => 4,
          'events' => [
            {
              'eventCode' => '4x50MI',
              'eventGender' => 'X',
              'eventLength' => '4x50',
              'eventStroke' => 'MI',
              'eventDescription' => '4x50 m Misti',
              'relay' => true,
              'results' => [
                {
                  'ranking' => '5',
                  'team' => 'Anon Team',
                  'timing' => '2\'00.00',
                  'category' => '',
                  'laps' => [
                    { 'distance' => '50m',  'timing' => '30.00', 'delta' => '30.00', 'swimmer' => '|ALF|Ana|1988|Anon Team' },
                    { 'distance' => '100m', 'timing' => '60.00', 'delta' => '30.00', 'swimmer' => '|BOB|Ben|1987|Anon Team' },
                    { 'distance' => '150m', 'timing' => '90.00', 'delta' => '30.00', 'swimmer' => '|CAL|Cat|1986|Anon Team' },
                    { 'distance' => '200m', 'timing' => '2\'00.00', 'delta' => '30.00', 'swimmer' => '|DAN|Dom|1985|Anon Team' }
                  ]
                }
              ]
            }
          ]
        )
      end

      it 'maps blank relay category to 000-999 and expands swimmers without gender' do
        out = described_class.normalize(data_hash: relay_unknown_hash)
        section = out['sections'].first
        expect(section['fin_sesso']).to eq('X')
        expect(section['fin_sigla_categoria']).to eq('000-999')
        row = section['rows'].first
        expect(row['lap50']).to eq('30.00')
        expect(row['lap200']).to eq("2'00.00")
        expect(row['swimmer1']).to eq('ALF Ana')
        expect(row['gender_type1']).to be_nil
      end
    end
  end
end
