# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Phase5Populator, type: :strategy do
  subject do
    described_class.new(
      source_path: source_path,
      phase1_path: phase1_path,
      phase2_path: phase2_path,
      phase3_path: phase3_path,
      phase4_path: phase4_path
    )
  end

  let(:source_path) { 'spec/fixtures/results_sample.json' }
  let(:phase1_path) { 'spec/fixtures/results_sample-phase1.json' }
  let(:phase2_path) { 'spec/fixtures/results_sample-phase2.json' }
  let(:phase3_path) { 'spec/fixtures/results_sample-phase3.json' }
  let(:phase4_path) { 'spec/fixtures/results_sample-phase4.json' }

  describe '#parse_timing_string' do
    it 'parses timing with minutes and seconds' do
      result = subject.send(:parse_timing_string, "5'05.84")
      expect(result).to eq({ minutes: 5, seconds: 5, hundredths: 84 })
    end

    it 'parses timing with only seconds' do
      result = subject.send(:parse_timing_string, '58.45')
      expect(result).to eq({ minutes: 0, seconds: 58, hundredths: 45 })
    end

    it 'parses timing with apostrophe variants' do
      result = subject.send(:parse_timing_string, "1'30.50") # curly apostrophe
      expect(result).to eq({ minutes: 1, seconds: 30, hundredths: 50 })
    end

    it 'returns zero timing for blank input' do
      result = subject.send(:parse_timing_string, '')
      expect(result).to eq({ minutes: 0, seconds: 0, hundredths: 0 })
    end

    it 'handles timing without hundredths' do
      result = subject.send(:parse_timing_string, "2'15")
      expect(result).to eq({ minutes: 2, seconds: 15, hundredths: 0 })
    end
  end

  describe '#compute_timing_delta' do
    it 'computes delta between two timings' do
      current = { minutes: 1, seconds: 18, hundredths: 56 }
      previous = { minutes: 0, seconds: 37, hundredths: 23 }

      result = subject.send(:compute_timing_delta, current, previous)
      expect(result[:minutes]).to eq(0)
      expect(result[:seconds]).to eq(41)
      expect(result[:hundredths]).to eq(33)
    end

    it 'handles first lap (previous is zero)' do
      current = { minutes: 0, seconds: 37, hundredths: 23 }
      previous = { minutes: 0, seconds: 0, hundredths: 0 }

      result = subject.send(:compute_timing_delta, current, previous)
      expect(result).to eq(current)
    end

    it 'handles timing crossing minute boundary' do
      current = { minutes: 2, seconds: 5, hundredths: 12 }
      previous = { minutes: 1, seconds: 55, hundredths: 89 }

      result = subject.send(:compute_timing_delta, current, previous)
      expect(result[:minutes]).to eq(0)
      expect(result[:seconds]).to eq(9)
      expect(result[:hundredths]).to eq(23)
    end
  end

  describe '#build_swimmer_key' do
    it 'extracts swimmer key from source format' do
      result = {
        'swimmer' => 'F|ROSSI|Mario|1980|CSI Ober Ferrari'
      }

      key = subject.send(:build_swimmer_key, result)
      expect(key).to eq('ROSSI|Mario|1980')
    end

    it 'handles swimmer with different field name' do
      result = {
        'swimmer_name' => 'M|BIANCHI|Luca|1975|Team Name'
      }

      key = subject.send(:build_swimmer_key, result)
      expect(key).to eq('BIANCHI|Luca|1975')
    end

    it 'returns original string if format is unexpected' do
      result = {
        'swimmer' => 'SimpleString'
      }

      key = subject.send(:build_swimmer_key, result)
      expect(key).to eq('SimpleString')
    end
  end

  describe '#parse_event_type' do
    it 'parses 200m breaststroke event code' do
      event_type = subject.send(:parse_event_type, '200RA')
      expect(event_type).to be_a(GogglesDb::EventType)
      expect(event_type.length_in_meters).to eq(200)
      expect(event_type.stroke_type.code).to eq('RA') # Rana = Breaststroke
    end

    it 'parses 100m freestyle event code' do
      event_type = subject.send(:parse_event_type, '100SL')
      expect(event_type).to be_a(GogglesDb::EventType)
      expect(event_type.length_in_meters).to eq(100)
      expect(event_type.stroke_type.code).to eq('SL') # Stile Libero = Freestyle
    end

    it 'parses 50m butterfly event code' do
      event_type = subject.send(:parse_event_type, '50FA')
      expect(event_type).to be_a(GogglesDb::EventType)
      expect(event_type.length_in_meters).to eq(50)
      expect(event_type.stroke_type.code).to eq('FA') # Farfalla = Butterfly
    end

    it 'parses 200m individual medley event code' do
      event_type = subject.send(:parse_event_type, '200MI')
      expect(event_type).to be_a(GogglesDb::EventType)
      expect(event_type.length_in_meters).to eq(200)
      expect(event_type.stroke_type.code).to eq('MI') # Misti = Individual Medley
    end

    it 'returns nil for invalid event code' do
      event_type = subject.send(:parse_event_type, 'INVALID')
      expect(event_type).to be_nil
    end

    it 'returns nil for blank event code' do
      event_type = subject.send(:parse_event_type, '')
      expect(event_type).to be_nil
    end
  end

  describe '#parse_category_type' do
    it 'finds category by code' do
      category_type = subject.send(:parse_category_type, 'M75')
      expect(category_type).to be_a(GogglesDb::CategoryType)
      expect(category_type.code).to eq('M75')
    end

    it 'returns nil for unknown category' do
      category_type = subject.send(:parse_category_type, 'UNKNOWN')
      expect(category_type).to be_nil
    end

    it 'returns nil for blank category' do
      category_type = subject.send(:parse_category_type, '')
      expect(category_type).to be_nil
    end
  end

  describe '#parse_gender_type' do
    it 'finds female gender type' do
      gender_type = subject.send(:parse_gender_type, 'F')
      expect(gender_type).to be_a(GogglesDb::GenderType)
      expect(gender_type.code).to eq('F')
    end

    it 'finds male gender type' do
      gender_type = subject.send(:parse_gender_type, 'M')
      expect(gender_type).to be_a(GogglesDb::GenderType)
      expect(gender_type.code).to eq('M')
    end

    it 'handles lowercase gender code' do
      gender_type = subject.send(:parse_gender_type, 'f')
      expect(gender_type).to be_a(GogglesDb::GenderType)
      expect(gender_type.code).to eq('F')
    end

    it 'returns nil for blank gender' do
      gender_type = subject.send(:parse_gender_type, '')
      expect(gender_type).to be_nil
    end
  end

  describe '#detect_source_format' do
    context 'with LT2 format file (Molinella sample)' do
      let(:source_path) { 'spec/fixtures/results/season-182_Molinella_sample.json' }

      it 'detects LT2 format from original file' do
        raw_data = JSON.parse(File.read(source_path))
        expect(raw_data['layoutType']).to eq(2)
      end

      it 'normalizes LT2 to LT4 format during load' do
        subject.send(:load_phase_files!)
        # After normalization, source_data should be in LT4 format
        expect(subject.source_data['layoutType']).to eq(4)
        expect(subject.source_data['events']).to be_an(Array)
      end
    end

    context 'with LT2 format file (Saronno sample)' do
      let(:source_path) { 'spec/fixtures/results/season-192_Saronno_sample.json' }

      it 'detects LT2 format from original file' do
        raw_data = JSON.parse(File.read(source_path))
        expect(raw_data['layoutType']).to eq(2)
      end

      it 'normalizes LT2 to LT4 format during load' do
        subject.send(:load_phase_files!)
        # After normalization, source_data should be in LT4 format
        expect(subject.source_data['layoutType']).to eq(4)
        expect(subject.source_data['events']).to be_an(Array)
      end
    end

    context 'with LT4 format file' do
      let(:source_path) { 'spec/fixtures/import/sample-200RA-l4.json' }

      before(:each) do
        subject.send(:load_phase_files!)
      end

      it 'detects LT4 format based on layoutType field' do
        format = subject.send(:source_format)
        expect(format).to eq(:lt4)
      end

      it 'reads layoutType field from source' do
        layout_type = subject.source_data['layoutType']
        expect(layout_type).to eq(4)
      end
    end

    context 'with missing layoutType field' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:source_path) { File.join(temp_dir, 'no_layout_type.json') }

      before(:each) do
        File.write(source_path, JSON.generate({ 'name' => 'Test Meeting' }))
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'raises an error during load' do
        expect { subject.send(:load_phase_files!) }.to raise_error(/layoutType.*missing/)
      end
    end

    context 'with unknown layoutType value' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:source_path) { File.join(temp_dir, 'unknown_layout_type.json') }

      before(:each) do
        File.write(source_path, JSON.generate({ 'layoutType' => 99, 'name' => 'Test Meeting' }))
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'raises an error during load' do
        expect { subject.send(:load_phase_files!) }.to raise_error(/Unknown layoutType 99/)
      end
    end
  end

  # NOTE: Full integration tests (#populate!) require fixture files
  # These should be added once we have sample JSON files in spec/fixtures/

  describe 'relay population' do
    let(:relay_fixture_path) { 'spec/fixtures/import/sample-relay-4x50sl-l4.json' }
    let(:source_path) { relay_fixture_path }
    let(:phase1_path) { 'spec/fixtures/import/sample-relay-phase1.json' }
    let(:phase2_path) { 'spec/fixtures/import/sample-relay-phase2.json' }
    let(:phase3_path) { 'spec/fixtures/import/sample-relay-phase3.json' }
    let(:phase4_path) { 'spec/fixtures/import/sample-relay-phase4.json' }

    before(:each) do
      # Clear relay tables
      GogglesDb::DataImportMeetingRelayResult.delete_all
      GogglesDb::DataImportMeetingRelaySwimmer.delete_all
      GogglesDb::DataImportRelayLap.delete_all
    end

    context 'with relay fixture file' do
      it 'detects LT4 format' do
        raw_data = JSON.parse(File.read(relay_fixture_path))
        expect(raw_data['layoutType']).to eq(4)
        expect(raw_data['events']).to be_an(Array)
      end

      it 'has relay events' do
        raw_data = JSON.parse(File.read(relay_fixture_path))
        relay_events = raw_data['events'].select { |e| e['relay'] == true }
        expect(relay_events.size).to be > 0
      end
    end

    describe '#populate_lt4_relay_results!' do
      before(:each) do
        subject.send(:load_phase_files!)
      end

      it 'processes relay events only' do
        expect(subject).to receive(:create_mrr_record).at_least(:once)
        subject.send(:populate_lt4_relay_results!)
      end

      it 'creates DataImportMeetingRelayResult records' do
        expect do
          subject.send(:populate_lt4_relay_results!)
        end.to change(GogglesDb::DataImportMeetingRelayResult, :count)
      end

      it 'creates DataImportMeetingRelaySwimmer records' do
        expect do
          subject.send(:populate_lt4_relay_results!)
        end.to change(GogglesDb::DataImportMeetingRelaySwimmer, :count)
      end

      it 'creates DataImportRelayLap records' do
        expect do
          subject.send(:populate_lt4_relay_results!)
        end.to change(GogglesDb::DataImportRelayLap, :count)
      end

      it 'creates correct number of relay results' do
        subject.send(:populate_lt4_relay_results!)
        # Fixture has 2 events with 3 total results (2 + 1)
        expect(GogglesDb::DataImportMeetingRelayResult.count).to eq(3)
      end

      it 'creates correct number of relay swimmers' do
        subject.send(:populate_lt4_relay_results!)
        # Each relay result has 4 swimmers = 3 results × 4 = 12
        expect(GogglesDb::DataImportMeetingRelaySwimmer.count).to eq(12)
      end

      it 'creates correct number of relay laps' do
        subject.send(:populate_lt4_relay_results!)
        # Each relay result has 4 laps = 3 results × 4 = 12
        expect(GogglesDb::DataImportRelayLap.count).to eq(12)
      end

      it 'stores timing correctly in MRR' do
        subject.send(:populate_lt4_relay_results!)
        mrr = GogglesDb::DataImportMeetingRelayResult.first

        expect(mrr.minutes).to eq(1)
        expect(mrr.seconds).to be_between(0, 59)
        expect(mrr.hundredths).to be_between(0, 99)
      end

      it 'stores relay order correctly in swimmers' do
        subject.send(:populate_lt4_relay_results!)
        mrr = GogglesDb::DataImportMeetingRelayResult.first
        swimmers = GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: mrr.import_key)
                                                           .order(:relay_order)

        expect(swimmers.map(&:relay_order)).to eq([1, 2, 3, 4])
      end

      it 'stores lap distances correctly' do
        subject.send(:populate_lt4_relay_results!)
        mrr = GogglesDb::DataImportMeetingRelayResult.first
        laps = GogglesDb::DataImportRelayLap.where(parent_import_key: mrr.import_key)
                                            .order(:length_in_meters)

        expect(laps.map(&:length_in_meters)).to eq([50, 100, 150, 200])
      end

      it 'computes delta timing for laps' do
        subject.send(:populate_lt4_relay_results!)
        laps = GogglesDb::DataImportRelayLap.order(:length_in_meters).limit(2)

        # First lap should have delta timing
        expect(laps.first.minutes).to be >= 0
        expect(laps.first.seconds).to be_between(0, 59)
      end

      it 'computes from_start timing for laps' do
        subject.send(:populate_lt4_relay_results!)
        laps = GogglesDb::DataImportRelayLap.order(:length_in_meters).to_a

        # from_start should increase with each lap
        expect(laps[1].seconds_from_start).to be > laps[0].seconds_from_start
      end

      it 'updates statistics' do
        subject.send(:populate_lt4_relay_results!)
        stats = subject.stats

        expect(stats[:relay_results_created]).to eq(3)
        expect(stats[:relay_swimmers_created]).to eq(12)
        expect(stats[:relay_laps_created]).to eq(12)
      end

      it 'generates valid import_keys' do
        subject.send(:populate_lt4_relay_results!)
        mrr = GogglesDb::DataImportMeetingRelayResult.first

        expect(mrr.import_key).to be_present
        # Relay import keys include the relay code with gender prefix (M or S) e.g., M4X50SL
        expect(mrr.import_key).to match(/[MS]?4X50/i)
      end
    end
  end
end
