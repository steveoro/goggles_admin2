# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController, type: :controller do
  describe '#detect_layout_type' do
    subject { controller.send(:detect_layout_type, file_path) }

    context 'with LT2 format file (Molinella sample)' do
      let(:file_path) { 'spec/fixtures/results/season-182_Molinella_sample.json' }

      it 'returns 2' do
        expect(subject).to eq(2)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(2)
      end
    end

    context 'with LT2 format file (Saronno sample)' do
      let(:file_path) { 'spec/fixtures/results/season-192_Saronno_sample.json' }

      it 'returns 2' do
        expect(subject).to eq(2)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(2)
      end
    end

    context 'with LT4 format file' do
      let(:file_path) { 'spec/fixtures/import/sample-200RA-l4.json' }

      it 'returns 4' do
        expect(subject).to eq(4)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(4)
      end
    end

    context 'with missing layoutType field' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:file_path) { File.join(temp_dir, 'invalid.json') }

      before(:each) do
        # Create file without layoutType field
        File.write(file_path, JSON.generate({ 'name' => 'Test Meeting' }))
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'defaults to 2' do
        expect(subject).to eq(2)
      end
    end

    context 'with unparseable file' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:file_path) { File.join(temp_dir, 'corrupt.json') }

      before(:each) do
        File.write(file_path, 'not valid json{')
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'defaults to 2 (handles error gracefully)' do
        expect(subject).to eq(2)
      end
    end
  end

  describe '#resolve_working_source_path' do
    subject(:resolved_path) { controller.send(:resolve_working_source_path, file_path) }

    let(:temp_dir) { Dir.mktmpdir }
    let(:source_path) { File.join(temp_dir, 'meeting.json') }
    let(:lt4_path) { File.join(temp_dir, 'meeting-lt4.json') }

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    context 'with LT4 source file' do
      let(:file_path) { source_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 4, 'name' => 'LT4 meeting' }))
      end

      it 'returns the same path' do
        expect(resolved_path).to eq(source_path)
      end
    end

    context 'with LT2 source file and missing LT4 working copy' do
      let(:file_path) { source_path }

      before(:each) do
        lt2_payload = {
          'layoutType' => 2,
          'name' => 'LT2 meeting',
          'sections' => [
            {
              'title' => '50 SL M25',
              'rows' => [
                { 'name' => 'Rossi Mario', 'year' => 1985, 'team' => 'Team A', 'timing' => '00:31.00' }
              ]
            }
          ]
        }
        File.write(source_path, JSON.pretty_generate(lt2_payload))
      end

      it 'materializes and returns the sibling -lt4 path' do
        expect(resolved_path).to eq(lt4_path)
        expect(File.exist?(lt4_path)).to be true

        data = JSON.parse(File.read(lt4_path))
        expect(data['layoutType']).to eq(4)
        expect(data['events']).to be_an(Array)
        expect(data['events']).not_to be_empty
        expect(data['swimmers']).to be_present
      end
    end

    context 'with LT2 source file and existing LT4 working copy' do
      let(:file_path) { source_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 2, 'sections' => [] }))
        File.write(lt4_path, JSON.pretty_generate({ 'layoutType' => 4, 'name' => 'Existing working copy' }))
      end

      it 'reuses existing LT4 copy' do
        expect(resolved_path).to eq(lt4_path)
        data = JSON.parse(File.read(lt4_path))
        expect(data['name']).to eq('Existing working copy')
      end
    end

    context 'with phase file that points to LT2 source' do
      let(:phase3_path) { File.join(temp_dir, 'meeting-phase3.json') }
      let(:file_path) { phase3_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 2, 'sections' => [] }))
        PhaseFileManager.new(phase3_path).write!(
          data: { 'swimmers' => [] },
          meta: { 'source_path' => source_path }
        )
      end

      it 'resolves canonical LT4 working source path' do
        expect(resolved_path).to eq(lt4_path)
      end
    end
  end
end
