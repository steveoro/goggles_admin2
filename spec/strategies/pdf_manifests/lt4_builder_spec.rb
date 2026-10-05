# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::Lt4Builder, type: :strategy do
  let(:pdf_path) { 'crawler/data/manifests/999/manifest-2026-11-08-test.pdf' }
  let(:base_extraction) do
    {
      'meeting_name' => "17° TROFEO MASTER \"CITTA' DI TEST\"",
      'edition' => 17,
      'dates' => ['2026-11-08'],
      'venue_name' => 'Piscina Comunale di Test City',
      'address' => 'Via Cesare Miola 5',
      'city' => 'Test City',
      'province' => 'TS',
      'pool_length_meters' => 25,
      'lanes' => 8,
      'max_individual_events' => 2,
      'events' => [
        { 'distance' => 200, 'stroke' => 'RA', 'relay' => false, 'raw_label' => '200 m Rana' },
        { 'distance' => 50, 'stroke' => 'SL', 'relay' => false, 'raw_label' => '50 m Stile Libero' },
        { 'distance' => 4 * 50, 'stroke' => 'MI', 'relay' => true, 'relay_style' => '4x50', 'gender' => 'X',
          'raw_label' => 'MISTAFFETTA 4x50 m Misti' }
      ]
    }
  end

  def build(src)
    described_class.new(extracted: src, pdf_path: pdf_path, season_id: 999, model: 'test-model')
  end

  describe '#lt4_hash top-level fields' do
    subject(:lt4) { build(base_extraction).lt4_hash }

    it 'is a layoutType 4 hash' do
      expect(lt4['layoutType']).to eq(4)
    end

    it 'carries meetingName, title and edition' do
      expect(lt4['meetingName']).to eq("17° TROFEO MASTER \"CITTA' DI TEST\"")
      expect(lt4['title']).to eq(lt4['meetingName'])
      expect(lt4['edition']).to eq(17)
    end

    it 'emits dates as a comma-separated string' do
      expect(lt4['dates']).to eq('2026-11-08')
    end

    it 'emits venue fields for the Phase1Solver' do
      expect(lt4['venueName']).to eq('Piscina Comunale di Test City')
      expect(lt4['venueAddress']).to eq('Via Cesare Miola 5, Test City (TS)')
      expect(lt4['cityName']).to eq('Test City')
      expect(lt4['place']).to eq('Piscina Comunale di Test City, Via Cesare Miola 5, Test City (TS)')
    end

    it 'emits poolLength and maxIndividualEvents' do
      expect(lt4['poolLength']).to eq('25')
      expect(lt4['maxIndividualEvents']).to eq(2)
    end

    it 'emits empty swimmers/teams for the meeting-only import' do
      expect(lt4['swimmers']).to eq({})
      expect(lt4['teams']).to eq({})
    end

    it 'emits one manifestSession per distinct date' do
      expect(lt4['manifestSessions']).to eq([{ 'date' => '2026-11-08', 'session_order' => 1 }])
    end

    it 'records provenance in _meta' do
      expect(lt4['_meta']['model']).to eq('test-model')
      expect(lt4['_meta']['meeting_only']).to be(true)
      expect(lt4['_meta']['source_manifest']).to eq(pdf_path)
    end
  end

  describe 'event normalization' do
    subject(:events) { build(base_extraction).lt4_hash['events'] }

    it 'normalizes individual events to eventCode/eventLength/eventStroke' do
      rana = events.find { |e| e['eventCode'] == '200RA' }
      expect(rana['eventLength']).to eq('200')
      expect(rana['eventStroke']).to eq('RA')
      expect(rana['relay']).to be(false)
      expect(rana['results']).to eq([])
    end

    it 'normalizes relays with M prefix and NxM eventLength' do
      relay = events.find { |e| e['eventCode'] == 'M4X50MI' }
      expect(relay).to be_present
      expect(relay['relay']).to be(true)
      expect(relay['eventLength']).to eq('4X50')
      expect(relay['eventGender']).to eq('X')
    end

    it 'assigns sessionOrder/eventOrder' do
      expect(events.pluck('sessionOrder').uniq).to eq([1])
      expect(events.pluck('eventOrder')).to eq([1, 2, 3])
    end

    it 'skips events with invalid distances and warns' do
      src = base_extraction.deep_dup
      src['events'] = [{ 'distance' => 999, 'stroke' => 'SL', 'raw_label' => '999 libero' }]
      b = build(src)
      expect(b.lt4_hash['events']).to be_empty
      expect(b.warnings.join).to include('invalid distance')
    end

    it 'resolves strokes from the raw label when the stroke field is missing' do
      src = base_extraction.deep_dup
      src['events'] = [{ 'distance' => 100, 'stroke' => nil, 'relay' => false, 'raw_label' => '100 dorso' }]
      expect(build(src).lt4_hash['events'].first['eventCode']).to eq('100DO')
    end

    it 'normalizes MX/misti labels to MI' do
      src = base_extraction.deep_dup
      src['events'] = [{ 'distance' => 400, 'stroke' => 'MX', 'relay' => false, 'raw_label' => '400 MX' }]
      expect(build(src).lt4_hash['events'].first['eventCode']).to eq('400MI')
    end

    it 'detects same-gender staffetta with the S prefix' do
      src = base_extraction.deep_dup
      src['events'] = [{ 'stroke' => 'SL', 'relay' => true, 'relay_style' => '4x50',
                         'raw_label' => 'STAFFETTA 4x50 m Stile Libero' }]
      expect(build(src).lt4_hash['events'].first['eventCode']).to eq('S4X50SL')
    end

    it 'detects mistaffetta as mixed relay' do
      src = base_extraction.deep_dup
      src['events'] = [{ 'stroke' => nil, 'relay' => true, 'relay_style' => '4x50',
                         'raw_label' => 'MISTAFFETTA 4x50 m Stile Libero' }]
      ev = build(src).lt4_hash['events'].first
      expect(ev['eventCode']).to eq('M4X50SL')
      expect(ev['eventGender']).to eq('X')
    end

    it 'drops duplicate events within the same session' do
      src = base_extraction.deep_dup
      src['events'] << { 'distance' => 200, 'stroke' => 'RA', 'relay' => false, 'raw_label' => '200 rana (bis)' }
      b = build(src)
      expect(b.lt4_hash['events'].pluck('eventCode').count('200RA')).to eq(1)
      expect(b.warnings.join).to include("duplicate event '200RA'")
    end

    it 'maps events to sessions by session_date when multiple dates exist' do
      src = base_extraction.deep_dup
      src['dates'] = %w[2026-11-07 2026-11-08]
      src['events'] = [
        { 'distance' => 400, 'stroke' => 'SL', 'relay' => false, 'session_date' => '2026-11-07' },
        { 'distance' => 200, 'stroke' => 'FA', 'relay' => false, 'session_date' => '2026-11-08' }
      ]
      lt4 = build(src).lt4_hash
      expect(lt4['dates']).to eq('2026-11-07,2026-11-08')
      expect(lt4['manifestSessions'].size).to eq(2)
      expect(lt4['events'].find { |e| e['eventCode'] == '400SL' }['sessionOrder']).to eq(1)
      expect(lt4['events'].find { |e| e['eventCode'] == '200FA' }['sessionOrder']).to eq(2)
    end

    it 'keeps the day_part metadata on events' do
      src = base_extraction.deep_dup
      src['events'].first['day_part'] = 'morning'
      expect(build(src).lt4_hash['events'].first['dayPart']).to eq('morning')
    end
  end

  describe 'warnings' do
    it 'warns when the extracted date differs from the filename date' do
      src = base_extraction.deep_dup
      src['dates'] = ['2026-12-25']
      expect(build(src).warnings.join).to include('!= filename date')
    end

    it 'warns when no dates are extracted' do
      src = base_extraction.deep_dup
      src['dates'] = []
      expect(build(src).warnings.join).to include('no meeting dates')
    end

    it 'warns when the meeting name is missing' do
      src = base_extraction.deep_dup
      src['meeting_name'] = nil
      expect(build(src).warnings.join).to include('meeting_name missing')
    end

    it 'derives edition from the meeting name when absent' do
      src = base_extraction.deep_dup
      src['edition'] = nil
      src['meeting_name'] = '25° Trofeo Città di Test'
      expect(build(src).lt4_hash['edition']).to eq(25)
    end
  end
end
