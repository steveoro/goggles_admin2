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

      before(:each) do
        subject.send(:load_phase_files!)
      end

      it 'detects LT2 format based on layoutType field' do
        format = subject.send(:source_format)
        expect(format).to eq(:lt2)
      end

      it 'reads layoutType field from source' do
        subject.send(:load_phase_files!)
        layout_type = subject.source_data['layoutType']
        expect(layout_type).to eq(2)
      end
    end

    context 'with LT2 format file (Saronno sample)' do
      let(:source_path) { 'spec/fixtures/results/season-192_Saronno_sample.json' }

      before(:each) do
        subject.send(:load_phase_files!)
      end

      it 'detects LT2 format based on layoutType field' do
        format = subject.send(:source_format)
        expect(format).to eq(:lt2)
      end

      it 'reads layoutType field from source' do
        layout_type = subject.source_data['layoutType']
        expect(layout_type).to eq(2)
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

      it 'raises an error' do
        subject.send(:load_phase_files!)
        expect { subject.send(:source_format) }.to raise_error(/layoutType.*missing/)
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

      it 'raises an error' do
        subject.send(:load_phase_files!)
        expect { subject.send(:source_format) }.to raise_error(/Unknown layoutType 99/)
      end
    end
  end

  # NOTE: Full integration tests (#populate!) require fixture files
  # These should be added once we have sample JSON files in spec/fixtures/
end
