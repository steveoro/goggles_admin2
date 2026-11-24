# frozen_string_literal: true

require 'rails_helper'

# Phase 15: the one manifest-extraction path. The outcomes (status + message) are the ones the former
# ManifestExtractJob#run_extractor produced; the engine and the Extractor are stubbed, files live in a temp root.
RSpec.describe PdfManifests::Extraction do
  let(:data_root) { Pathname.new(Dir.mktmpdir('extraction-')) }
  let(:pdf_path) { data_root.join('manifests', '262', 'manifest-x.pdf') }
  let(:txt_path) { pdf_path.sub_ext('.txt') }
  let(:client) { instance_double(PdfManifests::DevinClient, available?: true, model_available?: true) }
  let(:extractor) { instance_double(PdfManifests::Extractor) }

  def extractor_result(**attrs) = PdfManifests::Extractor::Result.new(pdf_path: pdf_path.to_s, warnings: [], **attrs)

  def call(**options) = described_class.call(pdf_path:, data_root:, client:, **options)

  before(:each) do
    FileUtils.mkdir_p(pdf_path.dirname)
    File.write(pdf_path, '%PDF')
    File.write(txt_path, 'text')
    allow(PdfManifests::Extractor).to receive(:new).and_return(extractor)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'extracts into results.new of the data root and archives the PDF with its TXT' do
    allow(extractor).to receive(:call).and_return(extractor_result(out_path: 'x-lt4.json', events_count: 12))
    result = call
    expect(PdfManifests::Extractor).to have_received(:new).with(client:, results_root: data_root.join('results.new'))
    expect(result).to have_attributes(status: :done, message: 'extracted (12 events)', archived?: true, done?: true)
    expect(data_root.join('manifests.done', '262', 'manifest-x.pdf')).to exist
    expect(data_root.join('manifests.done', '262', 'manifest-x.txt')).to exist
    expect(pdf_path).not_to exist
  end

  it 'archives an archivable skip as done' do
    allow(extractor).to receive(:call).and_return(extractor_result(skipped_reason: PdfManifests::Extractor::SKIP_RESULTS_PRESENT))
    expect(call).to have_attributes(status: :done, message: 'skipped: results source already present', archived?: true)
  end

  it 'keeps the PDF on a failed extraction' do
    allow(extractor).to receive(:call).and_return(extractor_result(skipped_reason: 'LLM returned no JSON'))
    expect(call).to have_attributes(status: :failed, message: 'extraction failed: LLM returned no JSON', archived?: false)
    expect(pdf_path).to exist
  end

  it 'passes force on' do
    allow(extractor).to receive(:call).and_return(extractor_result(out_path: 'x', events_count: 1))
    call(force: true)
    expect(extractor).to have_received(:call).with(pdf_path.to_s, force: true)
  end

  it 'stops at the preflight without calling the extractor' do
    allow(client).to receive(:available?).and_return(false)
    allow(extractor).to receive(:call)
    expect(call).to have_attributes(status: :failed, message: 'LLM engine unavailable', preflight: :engine_unavailable)
    allow(client).to receive_messages(available?: true, model_available?: false)
    expect(call).to have_attributes(status: :failed, message: 'LLM model missing', preflight: :model_missing)
    expect(extractor).not_to have_received(:call)
  end

  it 'skips the preflight when the caller already ran it' do
    allow(client).to receive(:available?).and_return(false)
    allow(extractor).to receive(:call).and_return(extractor_result(out_path: 'x', events_count: 1))
    expect(call(preflight: false)).to have_attributes(status: :done)
  end

  it 'builds the engine client when none is given' do
    allow(PdfManifests::ClientFactory).to receive(:build).with(engine: 'ollama', model: nil).and_return(client)
    allow(extractor).to receive(:call).and_return(extractor_result(out_path: 'x', events_count: 1))
    described_class.call(pdf_path:, data_root:, engine: 'ollama')
    expect(PdfManifests::ClientFactory).to have_received(:build).with(engine: 'ollama', model: nil)
  end

  describe '.archive' do
    it 'does nothing for a file outside a manifests folder' do
      other = data_root.join('pdfs', '262', 'x.pdf')
      FileUtils.mkdir_p(other.dirname)
      File.write(other, '%PDF')
      expect(described_class.archive(other)).to be false
      expect(other).to exist
    end
  end

  describe '.preflight_message' do
    it 'tells the engine and its hint' do
      devin = instance_double(PdfManifests::DevinClient, engine_name: 'devin', unavailable_hint: 'install it', model: 'm', model_missing_hint: 'pick')
      allow(PdfManifests::ClientFactory).to receive(:build).and_return(devin)
      expect(described_class.preflight_message(:engine_unavailable)).to eq(I18n.t('sources.manifests.extract.engine_unavailable', engine: 'devin',
                                                                                                                                  hint: 'install it'))
      expect(described_class.preflight_message(:model_missing)).to eq(I18n.t('sources.manifests.extract.model_missing', model: 'm', engine: 'devin', hint: 'pick'))
    end
  end
end
