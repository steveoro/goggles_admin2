# frozen_string_literal: true

require 'rails_helper'

# Smoke journey 10: Pull result files list & its file-actions modal.
#
# The listing globs crawler/data/results.new/<season>/**/*.json; the globs are redirected to a temporary
# "crawler/" tree, so that nothing depends on (nor writes into) the real crawler/data folder.
RSpec.describe 'Pull result files' do
  let(:tmp_root) { Dir.mktmpdir('system-pull-') }
  let(:season_dir) { File.join(tmp_root, 'crawler/data/results.new/242') }
  let(:json_path) { File.join(season_dir, '2026-01-01-smoke-meeting-l4.json') }

  before(:each) do
    FileUtils.mkdir_p(season_dir)
    File.write(json_path, JSON.generate({ 'layoutType' => 4, 'name' => 'Smoke meeting' }))
    real_root = Pathname.new(Rails.root.to_s)
    tmp_tree = Pathname.new(tmp_root)
    allow(Rails.root).to receive(:glob) do |pattern, *args|
      (pattern.to_s.start_with?('crawler/') ? tmp_tree : real_root).glob(pattern, *args)
    end
    sign_in_admin(prepare_admin_user)
    visit(pull_result_files_path)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  describe 'journey 10: file actions modal' do
    it 'opens the Edit modal and closes it leaving no backdrop behind' do
      expect(page).to have_css('table td', text: File.basename(json_path))
      expect(page).to have_no_css('#file-actions-modal.show')

      find('a[href*="pull/edit_file"]').click

      expect(page).to have_css('#file-actions-modal.show')
      expect(page).to have_css('#file-actions-modal textarea#new_content')
      expect(page).to have_css('.modal-backdrop.show')
      sleep(0.6) # (Bootstrap ignores a hide request while the fade-in transition is still running)
      find('#file-actions-modal .modal-footer [data-bs-dismiss="modal"]').click

      expect(page).to have_no_css('#file-actions-modal.show')
      expect_no_modal_backdrop
      expect_no_js_errors
    end
  end
end
