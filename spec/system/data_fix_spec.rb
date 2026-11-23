# frozen_string_literal: true

require 'rails_helper'

# Smoke journeys 8-9: Data-Fix v2 review pages on a temporary copy of the "sample-200RA-l4" fixtures
# (nothing is ever written into spec/fixtures or crawler/data).
RSpec.describe 'Data-Fix review pages' do
  let(:fixtures_dir) { Rails.root.join('spec/fixtures/import') }
  let(:tmp_root) { Dir.mktmpdir('system-data-fix-') }
  let(:work_dir) { File.join(tmp_root, '242') } # (the season ID is read from the folder name)
  let(:source_path) { File.join(work_dir, 'sample-200RA-l4.json') }
  let(:phase1_path) { File.join(work_dir, 'sample-200RA-l4-phase1.json') }

  before(:each) do
    FileUtils.mkdir_p(work_dir)
    FileUtils.cp(Dir[fixtures_dir.join('sample-200RA-l4*.json')], work_dir)
    sign_in_admin(prepare_admin_user)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  describe 'journey 8: step 1 (sessions)' do
    before(:each) { visit(review_sessions_path(file_path: source_path, phase_v2: 1)) }

    it 'collapses & expands the meeting card, saves a field and shows the five step tabs' do
      expect(page).to have_css('#meeting-card')
      expect(page).to have_css('ul.nav-tabs .nav-link', count: 5)
      (1..5).each { |step| expect(page).to have_css('ul.nav-tabs .nav-link', text: "Step #{step}") }
      expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 1')

      # The collapse starts closed or open depending on the data completeness: toggle it twice.
      initially_open = page.has_css?('#meeting-collapse.show', wait: 0)
      find_by_id('meeting-header').click
      expect(page).to initially_open ? have_no_css('#meeting-collapse.show') : have_css('#meeting-collapse.show')
      sleep(0.4) # (Bootstrap ignores toggles while the transition is still running)
      find_by_id('meeting-header').click
      expect(page).to initially_open ? have_css('#meeting-collapse.show') : have_no_css('#meeting-collapse.show')
      expect_no_js_errors
    end

    it 'saves an edited meeting field into the phase 1 file' do
      find_by_id('meeting-header').click unless page.has_css?('#meeting-collapse.show', wait: 0)
      expect(page).to have_css('#meeting-collapse.show')
      sleep(0.4)
      fill_in('meeting_description', with: 'Edited by the smoke journey')
      accept_confirm { click_button('Save Meeting') }

      expect(page).to have_css('#meeting-card', text: 'Edited by the smoke journey')
      expect(JSON.parse(File.read(phase1_path)).dig('data', 'name')).to eq('Edited by the smoke journey')
      expect_no_js_errors
    end
  end

  describe 'step 2 (teams): Bootstrap 4 → 5 attribute shim' do
    it 'keeps the custom data-target of .verify-team-btn while upgrading the collapse toggles' do
      visit(review_teams_path(file_path: source_path, phase2_v2: 1, filter_state: 'none'))

      # Copy, never move: a lone data-target is app data, read by the inline handler of the page.
      verify_button = first('.verify-team-btn', visible: :all)
      expect(verify_button['data-target']).to start_with('#team-verify-')
      expect(verify_button['data-bs-target']).to be_nil

      # BS4 toggles get their BS5 copies, keeping the original attributes:
      toggle = first('[data-toggle="collapse"][data-target]', visible: :all)
      expect(toggle['data-bs-toggle']).to eq('collapse')
      expect(toggle['data-bs-target']).to eq(toggle['data-target'])
      expect_no_js_errors
    end
  end

  describe 'journey 9: step 4 (events)' do
    it 'renders the add-event form with an initialised TomSelect' do
      visit(review_events_path(file_path: source_path, phase4_v2: 1))

      expect(page).to have_css('#frm-add-event')
      expect(page).to have_css('#frm-add-event .ts-wrapper')
      expect_no_js_errors
    end
  end
end
