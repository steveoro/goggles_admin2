# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sources::FileEditor do
  subject(:editor) { described_class.new(user_id: 7) }

  let(:data_root) { Pathname.new(Dir.mktmpdir('file-editor-')) }
  let(:season_dir) { data_root.join('results.new', '262') }

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    allow(SeasonBoard::Snapshot).to receive(:invalidate!)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  describe '#save!' do
    let(:json_path) { season_dir.join('meeting.json') }

    before(:each) { File.write(json_path, '{"a":1}') }

    it 'refuses an invalid JSON with the parser error and leaves the file untouched' do
      message = I18n.t('sources.files.edit.invalid_json', error: 'X').split('(').first
      expect { editor.save!(json_path, '{"a": 1,') }.to raise_error(described_class::Refused, /\A#{Regexp.escape(message)}/)
      expect(File.read(json_path)).to eq('{"a":1}')
      expect(season_dir.children.map { |child| child.basename.to_s }).to eq(['meeting.json']) # (no temp file left)
    end

    it 'writes a valid JSON through a temp file renamed over the original' do
      allow(File).to receive(:rename).and_call_original
      expect(editor.save!(json_path, '{"a": 2}')).to be_nil
      expect(File.read(json_path)).to eq('{"a": 2}')
      expect(File).to have_received(:rename).with(satisfy { |from| File.basename(from.to_s).start_with?('.meeting.json.') }, json_path)
    end

    it 'saves CSV and TXT as they are' do
      csv = season_dir.join('x.csv')
      File.write(csv, 'a,b')
      editor.save!(csv, "not,json\n{")
      expect(File.read(csv)).to eq("not,json\n{")
    end

    context 'with a Data-Fix phase file' do
      let(:source) { season_dir.join('meeting-lt4.json') }
      let(:phase_path) { season_dir.join('meeting-lt4-phase2.json') }

      before(:each) do
        File.write(source, { 'layoutType' => 4 }.to_json)
        File.write(phase_path, { 'data' => { 'teams' => [] }, '_meta' => {} }.to_json)
      end

      it 'marks the phase as edited by the operator (file_editor) after the save' do
        expect(editor.save!(phase_path, { 'data' => { 'teams' => [{ 'key' => 'X' }] }, '_meta' => {} }.to_json)).to eq(2)
        saved = JSON.parse(File.read(phase_path))
        expect(saved.dig('data', 'teams')).to eq([{ 'key' => 'X' }])
        expect(saved.dig('_meta', 'operator_edit')).to include('user_id' => 7, 'actions' => ['file_editor'])
        expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(262).at_least(:once)
      end

      it 'refuses the save while a prepare job holds the source lease' do
        FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'meeting', lease_owner: 'job:abc', lease_expires_at: 10.minutes.from_now)
        expect { editor.save!(phase_path, '{}') }.to raise_error(described_class::Refused, I18n.t('pipeline_automation.review.edit_refused'))
        expect(JSON.parse(File.read(phase_path))).to have_key('data')
      end
    end
  end

  it 'renames into a new folder and deletes' do
    path = season_dir.join('a.json')
    File.write(path, '{}')
    target = data_root.join('results.new', '999', 'b.json')
    editor.rename!(path, target)
    expect(target).to exist
    editor.delete!(target)
    expect(target).not_to exist
  end
end
