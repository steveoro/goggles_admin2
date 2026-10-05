# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe PdfManifests::Extractor, type: :strategy do
  let(:client) { instance_double(PdfManifests::OllamaClient, model: 'test-model', vision_model: 'vision-model') }
  let(:extractor) { described_class.new(client: client) }
  let(:temp_dir) { Dir.mktmpdir('manifest_spec') }
  let(:season_dir) { File.join(temp_dir, 'manifests', '9999') }
  let(:pdf_path) { File.join(season_dir, 'manifest-2026-11-08-test.pdf') }

  let(:extracted) do
    {
      'meeting_name' => 'TEST MEETING',
      'dates' => ['2026-11-08'],
      'venue_name' => 'Piscina',
      'city' => 'Test',
      'pool_length_meters' => 25,
      'events' => [{ 'distance' => 100, 'stroke' => 'SL', 'relay' => false, 'raw_label' => '100 SL' }]
    }
  end

  let(:out_dir) { Rails.root.join('crawler/data/results.new/9999') }

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    File.write(pdf_path, '%PDF-1.4 fake')
  end

  after(:each) do
    FileUtils.rm_rf(temp_dir)
    FileUtils.rm_rf(out_dir)
  end

  describe '#call' do
    context 'when the PDF has a text layer' do
      before(:each) do
        text_extractor = instance_double(PdfManifests::TextExtractor)
        allow(PdfManifests::TextExtractor).to receive(:new).with(pdf_path).and_return(text_extractor)
        allow(text_extractor).to receive(:extract).and_return('x' * 200)
      end

      it 'writes the LT4 source under results.new/<season>/ and returns a successful Result' do
        allow(client).to receive(:generate).and_return(extracted)
        result = extractor.call(pdf_path)
        expect(result).to be_success
        expect(result.events_count).to eq(1)
        expect(File).to exist(result.out_path)
        lt4 = JSON.parse(File.read(result.out_path))
        expect(lt4['layoutType']).to eq(4)
        expect(lt4['meetingName']).to eq('TEST MEETING')
      end

      it 'skips when the output already exists, unless force: true' do
        allow(client).to receive(:generate).and_return(extracted)
        first = extractor.call(pdf_path)
        expect(first).to be_success

        second = extractor.call(pdf_path)
        expect(second).not_to be_success
        expect(second.skipped_reason).to include('already exists')

        third = extractor.call(pdf_path, force: true)
        expect(third).to be_success
      end

      it 'does not run a corrective pass when the extraction is clean' do
        allow(client).to receive(:generate).and_return(extracted)
        extractor.call(pdf_path)
        expect(client).to have_received(:generate).once
      end

      context 'with retriable issues in the first extraction' do
        # 'M4X50DO' does not exist in event_types -> retriable issue.
        let(:bad_extraction) do
          extracted.merge(
            'events' => [{ 'stroke' => 'DO', 'relay' => true, 'relay_style' => '4x50', 'gender' => 'X',
                           'raw_label' => 'STAFFETTA 4x50 m Dorso (mista)' }]
          )
        end

        it 'runs exactly one corrective pass and writes the corrected result' do
          allow(client).to receive(:generate).and_return(bad_extraction, extracted)
          result = extractor.call(pdf_path)
          expect(client).to have_received(:generate).twice
          lt4 = JSON.parse(File.read(result.out_path))
          expect(lt4['events'].pluck('eventCode')).to eq(['100SL'])
          expect(result.warnings.join).to include('corrective pass applied')
          expect(result.warnings.join).not_to include('M4X50DO')
        end

        it 'feeds the detected issues and valid codes back into the retry prompt' do
          prompts = []
          allow(client).to receive(:generate) do |prompt:, **_opts|
            prompts << prompt
            prompts.size == 1 ? bad_extraction : extracted
          end
          extractor.call(pdf_path)
          expect(prompts.size).to eq(2)
          expect(prompts.last).to include('M4X50DO')
          expect(prompts.last).to include('Valid event code catalog')
          expect(prompts.last).to include('MANIFEST TEXT')
        end

        it 'keeps the original output when the retry is no better' do
          allow(client).to receive(:generate).and_return(bad_extraction, bad_extraction)
          result = extractor.call(pdf_path)
          expect(result).to be_success
          expect(result.warnings.join).to include('M4X50DO')
          expect(result.warnings.join).to include('did not improve')
        end

        it 'keeps the original output when the corrective call fails' do
          calls = 0
          allow(client).to receive(:generate) do
            calls += 1
            raise(PdfManifests::OllamaClient::Error, 'correction boom') if calls > 1

            bad_extraction
          end
          result = extractor.call(pdf_path)
          expect(result).to be_success
          expect(result.warnings.join).to include('corrective extraction pass failed: correction boom')
        end
      end
    end

    context 'when the PDF has no text layer' do
      before(:each) do
        text_extractor = instance_double(PdfManifests::TextExtractor)
        allow(PdfManifests::TextExtractor).to receive(:new).with(pdf_path).and_return(text_extractor)
        allow(text_extractor).to receive(:extract).and_return(" \n ")
      end

      it 'skips with a warning when no vision model is available' do
        allow(client).to receive(:vision_available?).and_return(false)
        result = extractor.call(pdf_path)
        expect(result).not_to be_success
        expect(result.warnings.join).to include("vision model 'vision-model' not available")
      end

      it 'uses the vision model when available' do
        allow(client).to receive(:vision_available?).and_return(true)
        vision = instance_double(PdfManifests::VisionExtractor)
        allow(PdfManifests::VisionExtractor).to receive(:new).with(pdf_path).and_return(vision)
        allow(vision).to receive(:to_base64_images).and_return(['img64'])
        allow(client).to receive(:generate).with(hash_including(images: ['img64'])).and_return(extracted)

        result = extractor.call(pdf_path)
        expect(result).to be_success
        expect(result.warnings.join).to include('vision model')
      end
    end

    context 'when the season cannot be detected from the path' do
      it 'returns a skipped Result' do
        odd_path = File.join(temp_dir, 'no-season', 'manifest.pdf')
        FileUtils.mkdir_p(File.dirname(odd_path))
        File.write(odd_path, 'x')
        result = extractor.call(odd_path)
        expect(result).not_to be_success
        expect(result.skipped_reason).to include('cannot detect season_id')
      end
    end

    context 'when Ollama fails' do
      it 'returns the error as skipped_reason' do
        text_extractor = instance_double(PdfManifests::TextExtractor)
        allow(PdfManifests::TextExtractor).to receive(:new).with(pdf_path).and_return(text_extractor)
        allow(text_extractor).to receive(:extract).and_return('x' * 200)
        allow(client).to receive(:generate).and_raise(PdfManifests::OllamaClient::Error, 'boom')

        result = extractor.call(pdf_path)
        expect(result).not_to be_success
        expect(result.skipped_reason).to eq('boom')
      end
    end
  end
end
