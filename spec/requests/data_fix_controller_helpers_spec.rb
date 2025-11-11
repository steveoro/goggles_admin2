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
end
