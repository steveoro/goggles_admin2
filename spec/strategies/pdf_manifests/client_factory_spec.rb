# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::ClientFactory, type: :strategy do
  describe '.default_engine' do
    it "is 'devin' when MANIFEST_ENGINE is not set" do
      expect(described_class.default_engine).to eq('devin')
    end

    it 'honours MANIFEST_ENGINE' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MANIFEST_ENGINE', 'devin').and_return('ollama')
      expect(described_class.default_engine).to eq('ollama')
    end
  end

  describe '.build' do
    it 'defaults to the Devin engine' do
      expect(described_class.build).to be_a(PdfManifests::DevinClient)
    end

    it 'builds an OllamaClient for engine=ollama' do
      expect(described_class.build(engine: 'ollama')).to be_a(PdfManifests::OllamaClient)
    end

    it 'honours MANIFEST_ENGINE for the default client' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MANIFEST_ENGINE', 'devin').and_return('ollama')
      expect(described_class.build).to be_a(PdfManifests::OllamaClient)
    end

    it 'raises ArgumentError on an unknown engine' do
      expect { described_class.build(engine: 'nope') }
        .to raise_error(ArgumentError, /unknown extraction engine/)
    end

    it 'passes the model override through to the client' do
      expect(described_class.build(engine: 'devin', model: 'swe-2-max').model).to eq('swe-2-max')
      expect(described_class.build(engine: 'ollama', model: 'qwen3:8b').model).to eq('qwen3:8b')
    end
  end
end
