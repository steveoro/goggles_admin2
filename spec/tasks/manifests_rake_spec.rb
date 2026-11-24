# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# 'manifests:extract' (phase 15: one extraction path, PdfManifests::Extraction, inline one file at a time). The console
# output is the one of the former task (recorded on the same fixtures before the switch); the engine and the
# Extractor are stubbed (no LLM call), every file lives under a temporary data root.
RSpec.describe 'manifests:extract' do # rubocop:disable RSpec/DescribeClass
  let(:task) { Rake::Task['manifests:extract'] }
  let(:data_root) { Pathname.new(Dir.mktmpdir('manifests-rake-')) }
  let(:season_dir) { data_root.join('manifests', '262') }
  let(:pdf_path) { season_dir.join('manifest-2026-11-08-Trofeo.pdf') }
  let(:available) { true }
  let(:model_available) { true }
  let(:client) do
    instance_double(PdfManifests::DevinClient, available?: available, model_available?: model_available, engine_name: 'devin',
                                               model: 'swe-2-high', vision_available?: false, vision_model: nil,
                                               unavailable_hint: 'install the devin CLI', model_missing_hint: 'pick a model',
                                               models: { 'swe-2-high' => {}, 'swe-1' => {} })
  end
  let(:extractor) { instance_double(PdfManifests::Extractor) }

  def output_of(**env)
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    task.reenable
    capture = StringIO.new
    original = $stdout
    $stdout = capture
    task.invoke
    capture.string
  ensure
    $stdout = original
  end

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('manifests:extract')
    FileUtils.mkdir_p(season_dir)
    File.write(pdf_path, '%PDF')
    allow(PdfManifests::ClientFactory).to receive(:build).and_return(client)
    allow(PdfManifests::Extractor).to receive(:new).and_return(extractor)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  after(:each) do
    %w[season file force engine model].each { |key| ENV.delete(key) }
    FileUtils.rm_rf(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  def result(**attrs) = PdfManifests::Extractor::Result.new(pdf_path: pdf_path.to_s, warnings: [], **attrs)

  it 'prints the extraction of a file, archives it and records the activity entry' do
    out_path = data_root.join('results.new', '262', '2026-11-08-Trofeo-lt4.json').to_s
    allow(extractor).to receive(:call).and_return(result(out_path:, events_count: 12, warnings: ['no pool found']))

    output = output_of(file: pdf_path, season: 262)

    expect(output).to eq(
      "\r\n*** Task: manifests:extract - season: 262 ***\n" \
      "--> devin OK - text model: swe-2-high | (no vision model - scanned PDFs will be skipped)\n" \
      "--> Found 1 manifest file(s)\r\n\r\n" \
      "--> manifest-2026-11-08-Trofeo.pdf ... OK (12 events) -> 2026-11-08-Trofeo-lt4.json\n    " \
      "warn: no pool found\n" \
      "\r\n== Done: 1 extracted, 0 skipped, 0 failed ==\n"
    )
    expect(File).to exist(data_root.join('manifests.done', '262', pdf_path.basename))
    entry = SeasonBoard::ActivityLog.new.entry(SeasonBoard::ActivityLog.source_key('extract', pdf_path.to_s), :extract)
    expect(entry).to have_attributes(status: :done, message: 'extracted (12 events)', label: pdf_path.basename.to_s)
  end

  it 'prints an archivable skip and a failure' do
    other = season_dir.join('manifest-2026-11-09-Other.pdf')
    File.write(other, '%PDF')
    allow(extractor).to receive(:call).with(pdf_path.to_s, force: false)
                                      .and_return(result(skipped_reason: PdfManifests::Extractor::SKIP_OUTPUT_EXISTS))
    allow(extractor).to receive(:call).with(other.to_s, force: false)
                                      .and_return(result(skipped_reason: 'LLM returned no JSON'))

    output = output_of(season: 262)

    expect(output).to include("--> Found 2 manifest file(s)\r\n\r\n")
    expect(output).to include("--> manifest-2026-11-08-Trofeo.pdf ... skipped (output already exists)\n")
    expect(output).to include("--> manifest-2026-11-09-Other.pdf ... FAILED: LLM returned no JSON\n")
    expect(output).to end_with("\r\n== Done: 0 extracted, 1 skipped, 1 failed ==\n")
    expect(File).not_to exist(pdf_path)
    expect(File).to exist(other)
  end

  context 'when the engine is not available' do
    let(:available) { false }

    it 'aborts before extracting anything' do
      allow(extractor).to receive(:call)
      output = output_of(file: pdf_path)
      expect(output).to end_with("ABORTED: devin engine not available - install the devin CLI\n")
      expect(extractor).not_to have_received(:call)
    end
  end

  context 'when the model is missing' do
    let(:model_available) { false }

    it 'aborts listing the available models' do
      output = output_of(file: pdf_path)
      expect(output).to end_with("ABORTED: model 'swe-2-high' not available for devin - pick a model\r\n     Available models: swe-1, swe-2-high\n")
    end
  end

  it 'says so when there is nothing to extract' do
    FileUtils.rm_f(pdf_path)
    expect(output_of(season: 262)).to end_with("No manifest PDFs found.\n")
  end
end
