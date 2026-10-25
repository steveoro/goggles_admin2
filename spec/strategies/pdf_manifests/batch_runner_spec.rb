# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe PdfManifests::BatchRunner, type: :strategy do
  let(:data_root) { Pathname(Dir.mktmpdir('batch_runner_spec')) }
  let(:manifests_dir) { data_root.join('manifests/262') }
  let(:done_dir) { data_root.join('manifests.done/262') }
  let(:client) do
    instance_double(PdfManifests::OllamaClient, model: 'test-model',
                                                available?: true, model_available?: true)
  end
  let(:extractor) { instance_double(PdfManifests::Extractor) }

  before(:each) do
    allow(PdfManifests::OllamaClient).to receive(:new).and_return(client)
    allow(PdfManifests::Extractor).to receive(:new).and_return(extractor)
  end

  after(:each) do
    described_class.mark_inactive!
    FileUtils.rm_rf(data_root)
  end

  def make_pdf(name = 'manifest-test.pdf')
    FileUtils.mkdir_p(manifests_dir)
    path = manifests_dir.join(name)
    File.write(path, '%PDF fake')
    path
  end

  def make_runner
    described_class.new(season_id: 262, data_root: data_root)
  end

  describe '.archive' do
    it 'moves the pdf and its .txt sibling into manifests.done/<season>' do
      pdf_path = make_pdf
      File.write(pdf_path.to_s.sub('.pdf', '.txt'), 'text layer')

      described_class.archive(pdf_path)

      expect(File).not_to exist(pdf_path)
      expect(File).to exist(done_dir.join('manifest-test.pdf'))
      expect(File).to exist(done_dir.join('manifest-test.txt'))
    end

    it 'is a no-op for files stored outside a manifests dir' do
      stray = data_root.join('other/262')
      FileUtils.mkdir_p(stray)
      stray_pdf = stray.join('x.pdf')
      File.write(stray_pdf, 'fake')

      described_class.archive(stray_pdf)
      expect(File).to exist(stray_pdf)
    end
  end

  describe '#preflight_error' do
    it 'reports :ollama_unavailable when the client is down' do
      allow(client).to receive(:available?).and_return(false)
      expect(make_runner.preflight_error).to eq(:ollama_unavailable)
    end

    it 'reports :model_missing when the model is not pulled' do
      allow(client).to receive(:model_available?).and_return(false)
      expect(make_runner.preflight_error).to eq(:model_missing)
    end

    it 'reports :no_manifests when the season dir has no pdf' do
      expect(make_runner.preflight_error).to eq(:no_manifests)
    end

    it 'is nil when everything is ready' do
      make_pdf
      expect(make_runner.preflight_error).to be_nil
    end
  end

  describe '.running?' do
    it 'is false with no status file and no active flag' do
      expect(described_class.running?(data_root: data_root)).to be(false)
    end

    it 'is true while the process-local flag is set' do
      described_class.mark_active!
      expect(described_class.running?(data_root: data_root)).to be(true)
    end

    it 'is true with a fresh running status file, false when stale' do
      status_path = data_root.join(described_class::STATUS_FILENAME)
      File.write(status_path, JSON.generate('running' => true, 'updated_at' => Time.now.utc.iso8601))
      expect(described_class.running?(data_root: data_root)).to be(true)

      File.write(status_path, JSON.generate('running' => true,
                                            'updated_at' => (Time.now.utc - 3600).iso8601))
      expect(described_class.running?(data_root: data_root)).to be(false)
    end
  end

  describe '#start_in_thread!' do
    it 'sets the running flag synchronously before the thread runs' do
      runner = make_runner
      allow(runner).to receive(:call)
      runner.start_in_thread!
      expect(described_class.running?(data_root: data_root)).to be(true)
    end
  end

  describe '#call' do
    it 'archives successful and already-extracted manifests and records failures' do
      pdf_ok = make_pdf('manifest-ok.pdf')
      pdf_skip = make_pdf('manifest-skip.pdf')
      pdf_bad = make_pdf('manifest-bad.pdf')

      result_klass = PdfManifests::Extractor::Result
      allow(extractor).to receive(:call).with(pdf_ok, force: false)
                                        .and_return(result_klass.new(pdf_path: pdf_ok.to_s, out_path: 'x-lt4.json'))
      allow(extractor).to receive(:call).with(pdf_skip, force: false)
                                        .and_return(result_klass.new(pdf_path: pdf_skip.to_s,
                                                                     skipped_reason: 'output already exists: x'))
      allow(extractor).to receive(:call).with(pdf_bad, force: false)
                                        .and_return(result_klass.new(pdf_path: pdf_bad.to_s,
                                                                     skipped_reason: 'extraction failed'))

      stats = make_runner.call

      expect(stats).to eq(extracted: 1, skipped: 1, failed: 1)
      expect(File).to exist(done_dir.join('manifest-ok.pdf'))
      expect(File).to exist(done_dir.join('manifest-skip.pdf'))
      expect(File).to exist(pdf_bad) # failed files stay for a retry

      status = described_class.read_status(data_root: data_root)
      expect(status['running']).to be(false)
      expect(status['extracted']).to eq(1)
      expect(status['errors'].first).to include('manifest-bad.pdf')
    end

    it 'marks the runner as inactive after completion' do
      make_pdf
      allow(extractor).to receive(:call)
        .and_return(PdfManifests::Extractor::Result.new(out_path: 'x.json'))
      make_runner.call
      expect(described_class.running?(data_root: data_root)).to be(false)
    end

    it 'persists an ERROR status with finished_at when the batch aborts' do
      make_pdf
      allow(PdfManifests::Extractor).to receive(:new).and_raise(StandardError, 'boom')

      expect { make_runner.call }.to raise_error(StandardError, 'boom')
      status = described_class.read_status(data_root: data_root)
      expect(status).to include('running' => false, 'status' => 'ERROR', 'detail' => 'boom')
      expect(status['finished_at']).to be_present
      expect(described_class.running?(data_root: data_root)).to be(false)
    end

    it 'does nothing when preflight fails' do
      allow(client).to receive(:available?).and_return(false)
      allow(extractor).to receive(:call)
      expect(make_runner.call).to be_nil
      expect(extractor).not_to have_received(:call)
    end
  end
end
