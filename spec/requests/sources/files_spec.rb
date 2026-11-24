# frozen_string_literal: true

require 'rails_helper'

# Files tab and the file manager (rename, edit, delete) through Sources::FileGuard and Sources::FilePolicy (ported
# from the former file-list specs; the exit criterion: no path outside crawler/data).
RSpec.describe 'Sources files' do
  include_context 'with a Sources data root'

  let!(:json) { write_data('results.new/242/meeting.json', '{"a":1}') }
  let(:outside) { sources_base_dir.join('outside.json') }

  def html = response.parsed_body

  before(:each) { File.write(outside, '{"secret":true}') }

  describe 'GET /sources/files' do
    it 'lists every top-level folder, the read-only ones marked, and no state file action' do
      write_data('pdfs.backup/x.pdf', '%PDF')
      write_data('misc/0001-x.sql', 'SELECT 1;')
      write_data('season-board.json', '{}')
      get(sources_files_path)
      expect(response).to have_http_status(:success)
      names = html.css('#sources-files-table tr[data-sources-file]').pluck('data-sources-file')
      expect(names).to include('results.new', 'pdfs.backup', 'misc', 'season-board.json')
      expect(html.at_css('#sources-files-table tr[data-sources-file="pdfs.backup"]').text).to include(I18n.t('sources.files.read_only'))
      expect(html.at_css('#sources-files-table tr[data-sources-file="season-board.json"] .btn')).to be_nil
    end

    it 'lists a folder with the actions the policy allows (SQL left to the Outbox, read-only folders)' do
      write_data('results.new/242/0001-x-lt4.sql', 'SELECT 1;')
      get(sources_files_path(dir: 'results.new/242'))
      expect(html.at_css('tr[data-sources-file="meeting.json"] a[href^="/sources/files/edit"]')).to be_present
      expect(html.at_css('tr[data-sources-file="0001-x-lt4.sql"] .btn')).to be_nil
      write_data('redo/a.json', '{}')
      get(sources_files_path(dir: 'redo'))
      expect(html.at_css('#sources-files-read-only')).to be_present
      expect(html.at_css('tr[data-sources-file="a.json"] .btn')).to be_nil
    end

    it 'lists a symlink pointing outside the data root as such, without following it or offering an action' do
      File.symlink(sources_base_dir, data_root.join('escape'))
      get(sources_files_path)
      row = html.at_css('#sources-files-table tr[data-sources-file="escape"]')
      expect(row.text).to include(I18n.t('sources.files.outside_link'))
      expect(row.css('a, form')).to be_empty
    end

    it 'refuses a folder outside the data root' do
      get(sources_files_path(dir: '../..'))
      expect(response).to have_http_status(:see_other)
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
    end
  end

  describe 'rename' do
    it 'shows the form and renames inside the folder (bare name) or to another folder' do
      get(sources_file_rename_path(path: 'results.new/242/meeting.json'))
      expect(html.at_css('#frm-sources-file-rename input[name="new_path"]')['value']).to eq('results.new/242/meeting.json')
      patch(sources_file_update_name_path, params: { path: 'results.new/242/meeting.json', new_path: 'renamed.json' })
      expect(data_root.join('results.new/242/renamed.json')).to exist
      expect(response).to redirect_to(sources_files_path(dir: 'results.new/242', focus: 'renamed.json'))
      patch(sources_file_update_name_path, params: { path: 'results.new/242/renamed.json', new_path: 'results.done/242/moved.json' })
      expect(data_root.join('results.done/242/moved.json')).to exist
    end

    it 'refuses a source or a target outside the data root, into a read-only folder, or over an existing file' do
      [['../../outside.json', 'x.json', :outside], [outside.to_s, 'x.json', :outside],
       ['results.new/242/meeting.json', '../../stolen.json', :outside], ['results.new/242/meeting.json', outside.to_s, :exists],
       ['results.new/242/meeting.json', 'results.backup/x.json', :read_only_folder],
       ['results.new/242/meeting.json', 'results.new/242/meeting.json', :exists]].each do |path, new_path, reason|
        patch(sources_file_update_name_path, params: { path:, new_path: })
        expect(flash[:warning]).to eq(I18n.t("sources.files.refused.#{reason}")), "#{path} -> #{new_path}"
      end
      expect(json).to exist
      expect(sources_base_dir.join('stolen.json')).not_to exist
      expect(File.read(outside)).to eq('{"secret":true}')
    end

    it 'refuses a symlink pointing out of the data root as the file to rename' do
      File.symlink(outside, data_root.join('results.new/242/link.json'))
      patch(sources_file_update_name_path, params: { path: 'results.new/242/link.json', new_path: 'x.json' })
      expect(flash[:warning]).to eq(I18n.t('sources.files.refused.outside'))
      expect(outside).to exist
    end
  end

  describe 'edit' do
    it 'opens a JSON in the CodeMirror editor' do
      get(sources_file_edit_path(path: 'results.new/242/meeting.json'))
      form = html.at_css('form#frm-sources-file-edit')
      expect(form['data-controller']).to eq('sources-editor')
      expect(form['data-sources-editor-json-value']).to eq('true')
      expect(form.at_css('textarea[name="content"]').text.strip).to eq('{"a":1}')
    end

    it 'refuses to save an invalid JSON (not written) and saves a valid one' do
      patch(sources_file_update_path, params: { path: 'results.new/242/meeting.json', content: '{"a":' })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('sources.files.edit.invalid_json', error: 'X').split('(').first.strip))
      expect(File.read(json)).to eq('{"a":1}')
      patch(sources_file_update_path, params: { path: 'results.new/242/meeting.json', content: '{"a":2}' })
      expect(File.read(json)).to eq('{"a":2}')
      expect(flash[:notice]).to eq(I18n.t('sources.files.saved', name: 'meeting.json'))
    end

    it 'marks a saved phase file as an operator edit (file_editor)' do
      write_data('results.new/242/meeting-phase3.json', { 'data' => {}, '_meta' => {} }.to_json)
      patch(sources_file_update_path, params: { path: 'results.new/242/meeting-phase3.json', content: { 'data' => { 'x' => 1 } }.to_json })
      saved = JSON.parse(File.read(data_root.join('results.new/242/meeting-phase3.json')))
      expect(saved.dig('_meta', 'operator_edit', 'actions')).to eq(['file_editor'])
      expect(saved.dig('_meta', 'operator_edit', 'user_id')).to eq(admin_user.id)
      expect(flash[:notice]).to eq(I18n.t('sources.files.saved_phase', name: 'meeting-phase3.json', phase: 3))
    end

    it 'refuses to edit a PDF, an SQL script, a state file or a file outside the data root' do
      write_data('pdfs/242/a.pdf', '%PDF')
      write_data('results.new/242/0001-a.sql', 'SELECT 1;')
      write_data('season-board.json', '{}')
      { 'pdfs/242/a.pdf' => :not_editable, 'results.new/242/0001-a.sql' => :outbox_script, 'season-board.json' => :state_file,
        outside.to_s => :outside, '../outside.json' => :missing }.each do |path, reason|
        get(sources_file_edit_path(path:))
        expect(flash[:warning]).to eq(I18n.t("sources.files.refused.#{reason}")), path
        patch(sources_file_update_path, params: { path:, content: '{}' })
      end
      expect(File.read(outside)).to eq('{"secret":true}')
    end
  end

  describe 'delete' do
    it 'deletes a file and comes back to its folder' do
      delete(sources_file_delete_path, params: { path: 'results.new/242/meeting.json', return_to: '/sources/results?season_id=242' })
      expect(json).not_to exist
      expect(response).to redirect_to('/sources/results?season_id=242')
    end

    it 'refuses a file outside the data root (also through ../ or a symlink) and never follows an external return_to' do
      File.symlink(outside, data_root.join('results.new/242/link.json'))
      [outside.to_s, '../../outside.json', 'results.new/242/link.json'].each do |path|
        delete(sources_file_delete_path, params: { path:, return_to: 'https://evil.example/' })
        expect(response.location).not_to include('evil')
      end
      expect(outside).to exist
    end
  end
end
