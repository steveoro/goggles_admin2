# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Solvers::EventSolver do
  # Use existing season from test DB (no creation needed)
  let(:season) { GogglesDb::Season.find(242) }
  let(:temp_dir) { Dir.mktmpdir }
  let(:source_file) { File.join(temp_dir, 'sample.json') }

  after(:each) { FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir) }

  def write_json(tmpdir, name, hash)
    path = File.join(tmpdir, name)
    File.write(path, JSON.pretty_generate(hash))
    path
  end

  def default_phase4_path(src)
    dir = File.dirname(src)
    base = File.basename(src, File.extname(src))
    File.join(dir, "#{base}-phase4.json")
  end

  describe '#build! with LT2 input (sections-based)' do
    let(:lt4_data) do
      {
        'layoutType' => 4,
        'sections' => [
          {
            'sessionOrder' => 1,
            'rows' => [
              { 'distance' => '100', 'stroke' => 'SL', 'eventOrder' => 1 },
              { 'distance' => '200', 'stroke' => 'DO', 'eventOrder' => 2 },
              { 'distance' => '100', 'stroke' => 'SL', 'eventOrder' => 3 } # Duplicate, should be ignored
            ]
          },
          {
            'session_order' => 2,
            'rows' => [
              { 'distanceInMeters' => '50', 'style' => 'FA', 'event_order' => 1 }
            ]
          }
        ]
      }
    end

    before(:each) do
      File.write(source_file, JSON.generate(lt4_data))
    end

    it 'creates a phase4.json file' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      expect(File).to exist(phase_file)
    end

    it 'groups events by sessions' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      expect(data['sessions']).to be_an(Array)
      expect(data['sessions'].size).to eq(2)
    end

    it 'extracts unique events per session' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      # Should have 2 unique events (100SL and 200DO), not 3
      expect(session1_events.size).to eq(2)
      expect(session1_events.map { |e| e['key'] }).to include('100|SL', '200|DO')
    end

    it 'stores event attributes correctly' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      event_100sl = session1_events.find { |e| e['key'] == '100|SL' }

      expect(event_100sl['distance']).to eq('100')
      expect(event_100sl['stroke']).to eq('SL')
      expect(event_100sl['event_order']).to eq(1)
      expect(event_100sl['session_order']).to eq(1)
      expect(event_100sl['heat_type_id']).to eq(3) # Finals default
      expect(event_100sl['heat_type']).to eq('F')
    end

    it 'finds matching event_type_id from database' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      event_100sl = session1_events.find { |e| e['key'] == '100|SL' }

      # Should find EventType for 100SL
      expected_event_type = GogglesDb::EventType.find_by(code: '100SL')
      expect(event_100sl['event_type_id']).to eq(expected_event_type&.id)
    end

    it 'sorts events by event_order within each session' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      event_orders = session1_events.map { |e| e['event_order'] }

      expect(event_orders).to eq(event_orders.sort)
    end
  end

  describe '#build! with LT4 input (flat events array)' do
    let(:lt4_data) do
      {
        'layoutType' => 4,
        'events' => [
          { 'eventCode' => '200RA', 'sessionOrder' => 1, 'eventOrder' => 1 },
          { 'eventCode' => '100SL', 'sessionOrder' => 1, 'eventOrder' => 2 },
          { 'eventCode' => '50FA', 'sessionOrder' => 2, 'eventOrder' => 1 },
          { 'relay' => true, 'eventCode' => '4x50SL' } # Should be skipped
        ]
      }
    end

    before(:each) do
      File.write(source_file, JSON.generate(lt4_data))
    end

    it 'creates a phase4.json file' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      expect(File).to exist(phase_file)
    end

    it 'extracts distance and stroke from eventCode' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      all_events = data['sessions'].flat_map { |s| s['events'] }
      event_200ra = all_events.find { |e| e['key'] == '200RA' }

      expect(event_200ra['distance']).to eq('200')
      expect(event_200ra['stroke']).to eq('RA')
    end

    it 'processes relay events' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      all_events = data['sessions'].flat_map { |s| s['events'] }
      # Should have 4 events total: 3 individual + 1 relay
      expect(all_events.size).to eq(4)
      # Relay event is marked with relay: true, key uses computed total distance (4*50=200)
      relay_event = all_events.find { |e| e['relay'] == true }
      expect(relay_event).to be_present
      # Key format is gender_prefix + total_distance + stroke, e.g., S200SL for 4x50SL same-sex
      expect(relay_event['key']).to match(/[SM]\d+SL/i)
      expect(relay_event['distance']).to eq('200') # 4 × 50 = 200
    end

    it 'groups events by sessionOrder' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      expect(data['sessions'].size).to eq(2)
      session1 = data['sessions'].find { |s| s['session_order'] == 1 }
      session2 = data['sessions'].find { |s| s['session_order'] == 2 }

      # Session 1 now has 3 events (2 individual + 1 relay without sessionOrder defaults to 1)
      expect(session1['events'].size).to eq(3)
      expect(session2['events'].size).to eq(1)
    end
  end

  describe '#build! with phase1 integration' do
    let(:meeting) { FactoryBot.create(:meeting, season: season) }
    let(:session1) { FactoryBot.create(:meeting_session, meeting: meeting, session_order: 1) }
    let(:session2) { FactoryBot.create(:meeting_session, meeting: meeting, session_order: 2) }

    let(:lt4_data) do
      {
        'layoutType' => 4,
        'sections' => [
          { 'sessionOrder' => 1, 'rows' => [{ 'distance' => '100', 'stroke' => 'SL' }] },
          { 'sessionOrder' => 2, 'rows' => [{ 'distance' => '200', 'stroke' => 'DO' }] }
        ]
      }
    end

    before(:each) do
      phase1_path = File.join(temp_dir, 'sample-phase1.json')
      phase1_data = {
        '_meta' => {},
        'data' => {
          'meeting_session' => [
            { 'session_order' => 1, 'id' => session1.id },
            { 'session_order' => 2, 'id' => session2.id }
          ]
        }
      }
      File.write(phase1_path, JSON.generate(phase1_data))
      File.write(source_file, JSON.generate(lt4_data))
    end

    it 'includes meeting_session_id from phase1 data' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      event = session1_events.first

      expect(event['meeting_session_id']).to eq(session1.id)
    end

    it 'matches existing meeting_event_id when event exists in DB' do
      # Create an existing meeting event
      event_type = GogglesDb::EventType.find_by(code: '100SL')
      existing_event = FactoryBot.create(:meeting_event, meeting_session: session1, event_type: event_type)

      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session1_events = data['sessions'].find { |s| s['session_order'] == 1 }['events']
      event_100sl = session1_events.find { |e| e['key'] == '100|SL' }

      expect(event_100sl['id']).to eq(existing_event.id)
    end

    it 'sets meeting_event_id to nil for new events' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      data = JSON.parse(File.read(phase_file))['data']

      session2_events = data['sessions'].find { |s| s['session_order'] == 2 }['events']
      event_200do = session2_events.find { |e| e['key'] == '200|DO' }

      expect(event_200do['id']).to be_nil
    end
  end

  describe 'metadata generation' do
    let(:lt4_data) { { 'layoutType' => 4, 'sections' => [] } }

    before(:each) do
      File.write(source_file, JSON.generate(lt4_data))
    end

    it 'includes source_path in metadata' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      meta = JSON.parse(File.read(phase_file))['_meta']

      expect(meta['source_path']).to eq(source_file)
    end

    it 'includes season_id in metadata' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      meta = JSON.parse(File.read(phase_file))['_meta']

      expect(meta['season_id']).to eq(season.id)
    end

    it 'includes phase number in metadata' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      meta = JSON.parse(File.read(phase_file))['_meta']

      expect(meta['phase']).to eq(4)
    end

    it 'includes layoutType in metadata' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      meta = JSON.parse(File.read(phase_file))['_meta']

      expect(meta['layoutType']).to eq(4)
    end

    it 'includes generated_at timestamp' do
      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      meta = JSON.parse(File.read(phase_file))['_meta']

      expect(meta['generated_at']).to be_present
      expect { Time.zone.parse(meta['generated_at']) }.not_to raise_error
    end
  end

  describe 'edge cases' do
    it 'handles empty sections array' do
      data = { 'layoutType' => 4, 'sections' => [] }
      File.write(source_file, JSON.generate(data))

      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      parsed = JSON.parse(File.read(phase_file))['data']

      expect(parsed['sessions']).to eq([])
    end

    it 'handles empty events array for LT4' do
      data = { 'layoutType' => 4, 'events' => [] }
      File.write(source_file, JSON.generate(data))

      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      parsed = JSON.parse(File.read(phase_file))['data']

      expect(parsed['sessions']).to eq([])
    end

    it 'skips rows with missing distance or stroke' do
      data = {
        'layoutType' => 4,
        'sections' => [
          {
            'rows' => [
              { 'distance' => '100', 'stroke' => '' },
              { 'distance' => '', 'stroke' => 'SL' },
              { 'distance' => '200', 'stroke' => 'DO' }
            ]
          }
        ]
      }
      File.write(source_file, JSON.generate(data))

      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      parsed = JSON.parse(File.read(phase_file))['data']

      events = parsed['sessions'].first['events']
      expect(events.size).to eq(1)
      expect(events.first['key']).to eq('200|DO')
    end

    it 'uses fallback event_order when not provided' do
      data = {
        'layoutType' => 4,
        'sections' => [
          {
            'rows' => [
              { 'distance' => '100', 'stroke' => 'SL' }, # No eventOrder
              { 'distance' => '200', 'stroke' => 'DO' }  # No eventOrder
            ]
          }
        ]
      }
      File.write(source_file, JSON.generate(data))

      described_class.new(season: season).build!(source_path: source_file, lt_format: 4)
      phase_file = default_phase4_path(source_file)
      parsed = JSON.parse(File.read(phase_file))['data']

      events = parsed['sessions'].first['events']
      # Should default to row index + 1
      expect(events[0]['event_order']).to eq(1)
      expect(events[1]['event_order']).to eq(2)
    end
  end
end
