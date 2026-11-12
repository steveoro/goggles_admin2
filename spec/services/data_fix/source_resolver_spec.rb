# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe DataFix::SourceResolver, type: :service do
  subject(:resolver) { described_class.new }

  let(:temp_dir) { Dir.mktmpdir('source_resolver_spec') }
  let(:lt2_path) { File.join(temp_dir, '2026-11-08-test-meeting.json') }
  let(:lt4_path) { File.join(temp_dir, '2026-11-08-test-meeting-lt4.json') }
  let(:phase_paths) { (1..5).map { |n| File.join(temp_dir, "2026-11-08-test-meeting-lt4-phase#{n}.json") } }

  let(:lt2_header) do
    {
      'layoutType' => 2,
      'name' => 'Test Meeting',
      'meetingURL' => 'https://example.test/risultati?id=1',
      'manifestURL' => 'https://example.test/manifest?file=abc',
      'dateDay1' => '08', 'dateMonth1' => 'Novembre', 'dateYear1' => '2026',
      'venue1' => 'Test Pool'
    }
  end
  let(:lt2_with_results) do
    lt2_header.merge(
      'sections' => [
        {
          'title' => '50 Stile Libero - M45',
          'fin_sesso' => 'M',
          'fin_sigla_categoria' => 'M45',
          'rows' => [{ 'pos' => '1', 'name' => 'ROSSI Mario', 'year' => '1978', 'sex' => 'M',
                       'team' => 'Team A', 'timing' => '31.00' }]
        }
      ]
    )
  end
  let(:lt2_result_free) { lt2_header.merge('sections' => []) }

  # Shape written by PdfManifests::Lt4Builder.
  let(:manifest_lt4) do
    {
      'layoutType' => 4,
      'meetingURL' => 'https://example.test/risultati?id=1',
      'meetingName' => 'Test Meeting',
      'dates' => '2026-11-08',
      'swimmers' => {},
      'teams' => {},
      'events' => [{ 'eventCode' => '50SL', 'sessionOrder' => 1, 'eventOrder' => 1, 'results' => [] }],
      '_meta' => { 'generated_by' => 'PdfManifests::Extractor', 'meeting_only' => true, 'warnings' => [] }
    }
  end

  def write_json(path, payload)
    File.write(path, JSON.pretty_generate(payload))
  end

  def write_phase_files
    phase_paths.each { |path| write_json(path, { 'data' => {}, '_meta' => {} }) }
  end

  after(:each) { FileUtils.rm_rf(temp_dir) }

  describe '#resolve_working_source_path' do
    context 'with a manifest LT4 copy and an LT2 sibling that now has results' do
      before(:each) do
        write_json(lt2_path, lt2_with_results)
        write_json(lt4_path, manifest_lt4)
        write_phase_files
      end

      shared_examples 'supersedes the manifest copy' do
        it 'returns the LT4 path re-materialized from the LT2 results' do
          expect(resolved).to eq(lt4_path)
          data = JSON.parse(File.read(lt4_path))
          expect(data['layoutType']).to eq(4)
          expect(data.dig('_meta', 'meeting_only')).to be_nil
          expect(data['events'].flat_map { |ev| Array(ev['results']) }).not_to be_empty
          expect(data['meetingURL']).to eq(lt2_header['meetingURL'])
        end

        it 'backs up the manifest copy with the .orig.json naming' do
          resolved
          backup_path = File.join(temp_dir, '2026-11-08-test-meeting-lt4.orig.json')
          expect(File).to exist(backup_path)
          expect(JSON.parse(File.read(backup_path))).to eq(manifest_lt4)
        end

        it 'removes the stale phase 1..5 files' do
          resolved
          phase_paths.each { |path| expect(File).not_to exist(path) }
        end

        it 'keeps a .orig.json backup of each existing phase file before removing it' do
          resolved
          phase_paths.each do |path|
            backup = path.sub(/\.json\z/, '.orig.json')
            expect(File).to exist(backup)
            expect(JSON.parse(File.read(backup))).to eq('data' => {}, '_meta' => {})
          end
        end

        it 'clears the data_import_* rows bound to the LT4 source' do
          allow(GogglesDb::DataImportMeetingIndividualResult).to receive(:where).and_call_original
          resolved
          expect(GogglesDb::DataImportMeetingIndividualResult).to have_received(:where).with(phase_file_path: lt4_path)
        end

        it 'uses a numbered backup when a .orig.json already exists' do
          File.write(File.join(temp_dir, '2026-11-08-test-meeting-lt4.orig.json'), '{}')
          resolved
          expect(File).to exist(File.join(temp_dir, '2026-11-08-test-meeting-lt4.orig-2.json'))
        end
      end

      context 'when given the LT2 path' do
        subject(:resolved) { resolver.resolve_working_source_path(lt2_path) }

        it_behaves_like 'supersedes the manifest copy'
      end

      context 'when given the -lt4.json path directly' do
        subject(:resolved) { resolver.resolve_working_source_path(lt4_path) }

        it_behaves_like 'supersedes the manifest copy'
      end
    end

    context 'with a manifest LT4 copy and a still result-free LT2 sibling' do
      before(:each) do
        write_json(lt2_path, lt2_result_free)
        write_json(lt4_path, manifest_lt4)
        write_phase_files
      end

      [:lt2_path, :lt4_path].each do |given|
        it "reuses the manifest copy untouched (given #{given})" do
          before_content = File.read(lt4_path)
          expect(resolver.resolve_working_source_path(send(given))).to eq(lt4_path)
          expect(File.read(lt4_path)).to eq(before_content)
          expect(Dir.glob(File.join(temp_dir, '*.orig*.json'))).to be_empty
          phase_paths.each { |path| expect(File).to exist(path) }
        end
      end
    end

    context 'with a regular (non-manifest) LT4 working copy' do
      let(:working_copy) do
        Import::Adapters::Layout2To4.normalize(data_hash: lt2_with_results).merge('_meta' => { 'retry_needed' => false })
      end

      before(:each) do
        write_json(lt2_path, lt2_with_results)
        write_json(lt4_path, working_copy)
        write_phase_files
      end

      [:lt2_path, :lt4_path].each do |given|
        it "reuses the working copy untouched (given #{given})" do
          before_content = File.read(lt4_path)
          expect(resolver.resolve_working_source_path(send(given))).to eq(lt4_path)
          expect(File.read(lt4_path)).to eq(before_content)
          expect(Dir.glob(File.join(temp_dir, '*.orig*.json'))).to be_empty
          phase_paths.each { |path| expect(File).to exist(path) }
        end
      end
    end

    context 'with a manifest LT4 file and no LT2 sibling' do
      before(:each) { write_json(lt4_path, manifest_lt4) }

      it 'returns the manifest file untouched' do
        before_content = File.read(lt4_path)
        expect(resolver.resolve_working_source_path(lt4_path)).to eq(lt4_path)
        expect(File.read(lt4_path)).to eq(before_content)
      end
    end
  end
end
