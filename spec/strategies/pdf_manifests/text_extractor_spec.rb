# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe PdfManifests::TextExtractor, type: :strategy do
  let(:temp_dir) { Dir.mktmpdir('manifest_spec') }
  let(:pdf_path) { File.join(temp_dir, 'manifest-test.pdf') }

  before(:each) { File.write(pdf_path, '%PDF-1.4 fake') }
  after(:each) { FileUtils.rm_rf(temp_dir) }

  it 'raises when the file does not exist' do
    expect { described_class.new(File.join(temp_dir, 'nope.pdf')) }.to raise_error(described_class::Error)
  end

  it 'raises when the file is not a .pdf' do
    txt = File.join(temp_dir, 'file.txt')
    File.write(txt, 'x')
    expect { described_class.new(txt) }.to raise_error(described_class::Error)
  end

  describe '#extract' do
    it 'reuses an existing .txt sibling without invoking pdftotext' do
      File.write(pdf_path.sub(/\.pdf\z/i, '.txt'), 'cached text contents ' * 10)
      extractor = described_class.new(pdf_path)
      allow(extractor).to receive(:system)
      expect(extractor.extract).to include('cached text contents')
      expect(extractor).not_to have_received(:system)
    end

    it 'runs pdftotext -layout when no .txt sibling exists' do
      extractor = described_class.new(pdf_path)
      allow(extractor).to receive(:system).and_return(true)
      extractor.extract
      expect(extractor).to have_received(:system).with('pdftotext', '-layout', pdf_path, extractor.txt_path)
    end

    it 'raises when pdftotext fails' do
      extractor = described_class.new(pdf_path)
      allow(extractor).to receive(:system).and_return(false)
      expect { extractor.extract }.to raise_error(described_class::Error, /pdftotext failed/)
    end
  end

  describe '#image_only?' do
    it 'is true for empty or whitespace-only text' do
      File.write(pdf_path.sub(/\.pdf\z/i, '.txt'), "  \n\n  ")
      extractor = described_class.new(pdf_path)
      extractor.extract
      expect(extractor).to be_image_only
    end

    it 'is false for a real text layer' do
      File.write(pdf_path.sub(/\.pdf\z/i, '.txt'), 'Manifestazione Regionale ' * 10)
      extractor = described_class.new(pdf_path)
      extractor.extract
      expect(extractor).not_to be_image_only
    end
  end
end
