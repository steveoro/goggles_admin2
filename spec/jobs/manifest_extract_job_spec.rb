# frozen_string_literal: true

require 'rails_helper'
require_relative '../services/season_board/disk_fixtures'

RSpec.describe ManifestExtractJob do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('manifest-extract-job') }
  let(:fin_id) { '150091' }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:llm_client) { instance_double(PdfManifests::DevinClient) }
  let(:preflight_error) { nil }
  let(:runner) { instance_double(PdfManifests::BatchRunner, preflight_error:, client: llm_client) }
  let(:extractor) { instance_double(PdfManifests::Extractor) }
  let(:out_path) { path_for('results.new', 'm-lt4.json') }
  let(:result) { PdfManifests::Extractor::Result.new(pdf_path: pdf_path, out_path:, warnings: [], events_count: 12) }
  let(:pdf_path) { path_for('manifests', 'manifest-m.pdf') }

  def perform(engine: nil)
    described_class.perform_now(season_id: 262, fin_event_id: fin_id, engine:)
  end

  def extract_entry = activity_log.entry(fin_id, :extract)

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    described_class.data_dir = data_dir
    # A pending manifest is matched to the FIN id through its LT2 sibling:
    write_json('results.new', 'm.json', lt2_hash(fin_id:))
    write_file('manifests', 'manifest-m.pdf', '%PDF')
    allow(GogglesDb::Season).to receive(:find_by).with(id: 262).and_return(season)
    allow(PdfManifests::BatchRunner).to receive_messages(running?: false, new: runner)
    allow(PdfManifests::Extractor).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:call).and_return(result)
    allow(SeasonBoard::Notifier).to receive(:ping)
  end

  after(:each) do
    described_class.data_dir = nil
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'is enqueued on the background queue' do
    expect { described_class.perform_later(season_id: 262, fin_event_id: fin_id) }
      .to have_enqueued_job(described_class).on_queue('background')
  end

  it 'extracts the pending PDF with the requested engine & archives it' do
    perform(engine: 'ollama')
    expect(PdfManifests::BatchRunner).to have_received(:new).with(season_id: 262, engine: 'ollama', data_root: Pathname.new(data_dir))
    expect(PdfManifests::Extractor).to have_received(:new).with(client: llm_client, results_root: Pathname.new(data_dir).join('results.new'))
    expect(extractor).to have_received(:call).with(pdf_path)
    expect(File).not_to exist(pdf_path)
    expect(File).to exist(path_for('manifests.done', 'manifest-m.pdf'))
    expect(extract_entry).to have_attributes(status: :done, message: 'extracted (12 events)')
    expect(SeasonBoard::Notifier).to have_received(:ping)
  end

  it 'archives on an archivable skip' do
    allow(extractor).to receive(:call).and_return(
      PdfManifests::Extractor::Result.new(pdf_path:, skipped_reason: PdfManifests::Extractor::SKIP_OUTPUT_EXISTS)
    )
    perform
    expect(File).to exist(path_for('manifests.done', 'manifest-m.pdf'))
    expect(extract_entry).to have_attributes(status: :done, message: 'skipped: output already exists')
  end

  it 'keeps the PDF & fails on a non-archivable result' do
    allow(extractor).to receive(:call).and_return(PdfManifests::Extractor::Result.new(pdf_path:, skipped_reason: 'extraction failed'))
    perform
    expect(File).to exist(pdf_path)
    expect(extract_entry).to have_attributes(status: :failed, message: 'extraction failed: extraction failed')
  end

  it 'skips while a season-wide batch is running' do
    allow(PdfManifests::BatchRunner).to receive(:running?).and_return(true)
    perform
    expect(extractor).not_to have_received(:call)
    expect(extract_entry).to have_attributes(status: :failed, message: 'a season-wide manifest extraction is running')
  end

  context 'when the preflight check fails' do
    let(:preflight_error) { :engine_unavailable }

    it 'does not extract' do
      perform
      expect(extractor).not_to have_received(:call)
      expect(extract_entry).to have_attributes(status: :failed, message: 'LLM engine unavailable')
    end
  end

  it 'fails when no pending PDF exists for the FIN id' do
    FileUtils.rm_f(pdf_path)
    perform
    expect(extract_entry).to have_attributes(status: :failed, message: 'no pending manifest PDF for this FIN id')
  end

  it 'closes the activity as failed (without raising) on unexpected errors' do
    allow(extractor).to receive(:call).and_raise(RuntimeError, 'kaboom')
    expect { perform }.not_to raise_error
    expect(extract_entry).to have_attributes(status: :failed, message: 'error: RuntimeError: kaboom')
    expect(File).to exist(pdf_path)
  end
end
