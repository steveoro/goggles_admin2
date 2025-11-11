# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Adapters::Layout2To4 do
  describe '.normalize' do
    let(:header) do
      {
        'layoutType' => 2,
        'name' => 'Sample Meeting',
        'meetingURL' => 'http://example.test/meeting',
        'manifestURL' => 'http://example.test/manifest.pdf',
        'resultsPdfURL' => 'http://example.test/results.pdf',
        'dateDay1' => '07',
        'dateMonth1' => 'Aprile',
        'dateYear1' => '2024',
        'dateDay2' => '08',
        'dateMonth2' => 'Aprile',
        'dateYear2' => '2024',
        'venue1' => 'Sample Pool',
        'address1' => 'Via Test, 1 - Sample City',
        'poolLength' => '25',
        'season_id' => '232'
      }
    end

    context 'with individual event including laps' do
      let(:lt2_hash) do
        header.merge(
          'sections' => [
            {
              'title' => '100 Stile Libero - M45',
              'fin_sesso' => 'M',
              'fin_sigla_categoria' => 'M45',
              'rows' => [
                {
                  'pos' => '1',
                  'name' => 'ROSSI Mario',
                  'year' => '1978',
                  'sex' => 'M',
                  'team' => 'Sample Team',
                  'timing' => '1\'05.84',
                  'score' => '750.50',
                  'laps' => [
                    { 'distance' => 50, 'timing' => '31.20', 'delta' => '31.20' },
                    { 'distance' => 100, 'timing' => '1\'05.84', 'delta' => '34.64' }
                  ]
                },
                {
                  'pos' => '2',
                  'name' => 'BIANCHI Luca',
                  'year' => '1980',
                  'sex' => 'M',
                  'team' => 'Another Team',
                  'timing' => '1\'08.50',
                  'lap50' => '32.00',
                  'delta50' => '32.00',
                  'lap100' => '1\'08.50',
                  'delta100' => '36.50'
                }
              ]
            }
          ]
        )
      end

      it 'produces LT4-like structure with events array' do
        out = described_class.normalize(data_hash: lt2_hash)
        expect(out['layoutType']).to eq(4)
        expect(out['events']).to be_an(Array)
        expect(out['events'].size).to eq(1)
      end

      it 'converts header fields to LT4 format' do
        out = described_class.normalize(data_hash: lt2_hash)
        expect(out['meetingName']).to eq('Sample Meeting')
        expect(out['dates']).to eq('2024-04-07,2024-04-08')
        expect(out['place']).to eq('Sample Pool')
        expect(out['poolLength']).to eq('25')
        expect(out['seasonId']).to eq('232')
      end

      it 'builds lookup dictionaries for swimmers' do
        out = described_class.normalize(data_hash: lt2_hash)
        expect(out['swimmers']).to be_a(Hash)
        expect(out['swimmers'].size).to eq(2)

        swimmer_keys = out['swimmers'].keys
        expect(swimmer_keys).to include(match(/^M\|ROSSI\|Mario\|1978\|Sample Team$/))
        expect(swimmer_keys).to include(match(/^M\|BIANCHI\|Luca\|1980\|Another Team$/))
      end

      it 'builds lookup dictionaries for teams' do
        out = described_class.normalize(data_hash: lt2_hash)
        expect(out['teams']).to be_a(Hash)
        expect(out['teams'].size).to eq(2)
        expect(out['teams']['Sample Team']).to eq({ 'name' => 'Sample Team' })
        expect(out['teams']['Another Team']).to eq({ 'name' => 'Another Team' })
      end

      it 'converts sections to events with correct structure' do
        out = described_class.normalize(data_hash: lt2_hash)
        event = out['events'].first

        expect(event['eventCode']).to eq('100SL')
        expect(event['eventGender']).to eq('M')
        expect(event['eventLength']).to eq('100')
        expect(event['eventStroke']).to eq('SL')
        expect(event['eventDescription']).to eq('100 Stile Libero')
        expect(event['relay']).to be false
        expect(event['results']).to be_an(Array)
        expect(event['results'].size).to eq(2)
      end

      it 'converts rows to results with composite swimmer keys' do
        out = described_class.normalize(data_hash: lt2_hash)
        result = out['events'].first['results'].first

        expect(result['ranking']).to eq('1')
        expect(result['swimmer']).to match(/^M\|ROSSI\|Mario\|1978\|Sample Team$/)
        expect(result['team']).to eq('Sample Team')
        expect(result['timing']).to eq('1\'05.84')
        expect(result['score']).to eq('750.50')
        expect(result['category']).to eq('M45')
      end

      it 'converts laps array to LT4 format' do
        out = described_class.normalize(data_hash: lt2_hash)
        result = out['events'].first['results'].first

        expect(result['laps']).to be_an(Array)
        expect(result['laps'].size).to eq(2)
        expect(result['laps'][0]).to eq({
                                          'distance' => '50m',
                                          'timing' => '31.20',
                                          'delta' => '31.20'
                                        })
        expect(result['laps'][1]).to eq({
                                          'distance' => '100m',
                                          'timing' => '1\'05.84',
                                          'delta' => '34.64'
                                        })
      end

      it 'extracts inline laps from lap50/lap100 keys' do
        out = described_class.normalize(data_hash: lt2_hash)
        result = out['events'].first['results'][1] # Second swimmer has inline laps

        expect(result['laps']).to be_an(Array)
        expect(result['laps'].size).to eq(2)
        expect(result['laps'][0]).to eq({
                                          'distance' => '50m',
                                          'timing' => '32.00',
                                          'delta' => '32.00'
                                        })
        expect(result['laps'][1]).to eq({
                                          'distance' => '100m',
                                          'timing' => '1\'08.50',
                                          'delta' => '36.50'
                                        })
      end
    end

    context 'with relay event' do
      let(:relay_lt2_hash) do
        header.merge(
          'sections' => [
            {
              'title' => '4x50 Mista - 100-119',
              'fin_sesso' => 'X',
              'fin_sigla_categoria' => '100-119',
              'rows' => [
                {
                  'pos' => '1',
                  'relay' => true,
                  'team' => 'Mixed Team A',
                  'timing' => '1\'40.00',
                  'swimmer1' => 'ROSSI Mario',
                  'year_of_birth1' => '1978',
                  'gender_type1' => 'M',
                  'swimmer2' => 'BIANCHI Anna',
                  'year_of_birth2' => '1980',
                  'gender_type2' => 'F',
                  'swimmer3' => 'VERDI Luca',
                  'year_of_birth3' => '1975',
                  'gender_type3' => 'M',
                  'swimmer4' => 'NERI Sara',
                  'year_of_birth4' => '1982',
                  'gender_type4' => 'F',
                  'laps' => [
                    { 'distance' => 50, 'timing' => '25.00', 'delta' => '25.00', 'swimmer' => 'M|ROSSI|Mario|1978|Mixed Team A' },
                    { 'distance' => 100, 'timing' => '50.00', 'delta' => '25.00', 'swimmer' => 'F|BIANCHI|Anna|1980|Mixed Team A' },
                    { 'distance' => 150, 'timing' => '1\'15.00', 'delta' => '25.00', 'swimmer' => 'M|VERDI|Luca|1975|Mixed Team A' },
                    { 'distance' => 200, 'timing' => '1\'40.00', 'delta' => '25.00', 'swimmer' => 'F|NERI|Sara|1982|Mixed Team A' }
                  ]
                }
              ]
            }
          ]
        )
      end

      it 'identifies relay events correctly' do
        out = described_class.normalize(data_hash: relay_lt2_hash)
        event = out['events'].first

        expect(event['relay']).to be true
        expect(event['eventCode']).to eq('4x50MI')
        expect(event['eventDescription']).to eq('4x50 Mista')
      end

      it 'converts relay results with swimmers array' do
        out = described_class.normalize(data_hash: relay_lt2_hash)
        result = out['events'].first['results'].first

        expect(result['ranking']).to eq('1')
        expect(result['team']).to eq('Mixed Team A')
        expect(result['timing']).to eq('1\'40.00')
        expect(result['category']).to eq('100-119')
        expect(result['swimmers']).to be_an(Array)
        expect(result['swimmers'].size).to eq(4)
      end

      it 'preserves relay swimmer details' do
        out = described_class.normalize(data_hash: relay_lt2_hash)
        swimmers = out['events'].first['results'].first['swimmers']

        expect(swimmers[0]).to eq({
                                    'complete_name' => 'ROSSI Mario',
                                    'year_of_birth' => '1978',
                                    'gender_type' => 'M'
                                  })
        expect(swimmers[1]).to eq({
                                    'complete_name' => 'BIANCHI Anna',
                                    'year_of_birth' => '1980',
                                    'gender_type' => 'F'
                                  })
      end

      it 'converts relay laps with swimmer associations' do
        out = described_class.normalize(data_hash: relay_lt2_hash)
        laps = out['events'].first['results'].first['laps']

        expect(laps).to be_an(Array)
        expect(laps.size).to eq(4)
        expect(laps[0]).to eq({
                                'distance' => '50m',
                                'timing' => '25.00',
                                'delta' => '25.00',
                                'swimmer' => 'M|ROSSI|Mario|1978|Mixed Team A'
                              })
      end
    end

    context 'with multiple sections for same event' do
      let(:multi_section_lt2) do
        header.merge(
          'sections' => [
            {
              'title' => '50 Stile Libero - M25',
              'fin_sesso' => 'M',
              'fin_sigla_categoria' => 'M25',
              'rows' => [
                { 'pos' => '1', 'name' => 'YOUNG One', 'year' => '1999', 'sex' => 'M', 'team' => 'Team A', 'timing' => '25.00' }
              ]
            },
            {
              'title' => '50 Stile Libero - M45',
              'fin_sesso' => 'M',
              'fin_sigla_categoria' => 'M45',
              'rows' => [
                { 'pos' => '1', 'name' => 'OLDER One', 'year' => '1978', 'sex' => 'M', 'team' => 'Team B', 'timing' => '26.00' }
              ]
            }
          ]
        )
      end

      it 'merges multiple sections into single event with all results' do
        out = described_class.normalize(data_hash: multi_section_lt2)

        expect(out['events'].size).to eq(1)
        event = out['events'].first
        expect(event['eventCode']).to eq('50SL')
        expect(event['results'].size).to eq(2)

        # Results should have their respective categories
        categories = event['results'].map { |r| r['category'] }
        expect(categories).to contain_exactly('M25', 'M45')
      end
    end

    context 'with missing optional data' do
      let(:minimal_lt2) do
        {
          'layoutType' => 2,
          'name' => 'Minimal Meeting',
          'sections' => [
            {
              'title' => '50 Stile Libero',
              'rows' => [
                { 'name' => 'SWIMMER One', 'timing' => '30.00' }
              ]
            }
          ]
        }
      end

      it 'handles missing header fields gracefully' do
        out = described_class.normalize(data_hash: minimal_lt2)

        expect(out['layoutType']).to eq(4)
        expect(out['meetingName']).to eq('Minimal Meeting')
        expect(out['dates']).to be_nil
        expect(out['place']).to be_nil
      end

      it 'handles missing lap data gracefully' do
        out = described_class.normalize(data_hash: minimal_lt2)
        result = out['events'].first['results'].first

        expect(result['timing']).to eq('30.00')
        expect(result['laps']).to be_nil
      end
    end

    context 'with edge cases' do
      it 'raises ArgumentError if input is not a Hash' do
        expect { described_class.normalize(data_hash: 'not a hash') }.to raise_error(ArgumentError, /must be a Hash/)
      end

      it 'handles empty sections array' do
        out = described_class.normalize(data_hash: header.merge('sections' => []))

        expect(out['events']).to eq([])
        expect(out['swimmers']).to eq({})
        expect(out['teams']).to eq({})
      end

      it 'handles nil sections' do
        out = described_class.normalize(data_hash: header.merge('sections' => nil))

        expect(out['events']).to eq([])
      end
    end
  end
end
