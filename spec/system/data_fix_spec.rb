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
      accept_confirm { click_button(I18n.t('data_fix.wizard.buttons.save_meeting')) }

      expect(page).to have_css('#meeting-card', text: 'Edited by the smoke journey')
      expect(JSON.parse(File.read(phase1_path)).dig('data', 'name')).to eq('Edited by the smoke journey')
      expect_no_js_errors
    end
  end

  describe 'step 1: copy pool & city from another session' do
    it 'copies the fields of a session on the page and says when nothing was copied' do
      visit(review_sessions_path(file_path: source_path, phase_v2: 1, issues_only: '0'))
      find_by_id('session-header-1').click unless page.has_css?('#session-collapse-1.show', wait: 0)
      expect(page).to have_css('#session-collapse-1.show')
      sleep(0.4)
      within('#session-card-1') do
        click_button(I18n.t('data_import.data_fix.btn_copy_session_pool'))
        expect(page).to have_css('#copy-from-session-feedback-1.text-danger', text: I18n.t('data_fix.wizard.sessions.copy_missing'))
        page.execute_script("document.getElementById('pool_0_name').value = 'Copied Pool Name'")
        select_option = find('#copy_from_session_1 option[value="0"]')
        select_option.select_option
        click_button(I18n.t('data_import.data_fix.btn_copy_session_pool'))
        expect(page).to have_css('#copy-from-session-feedback-1.text-success', text: I18n.t('data_fix.wizard.sessions.copied'))
      end
      expect(find_by_id('pool_1_name', visible: :all).value).to eq('Copied Pool Name')
      expect_no_js_errors
    end
  end

  describe 'step 2 (teams): native Bootstrap 5 markup and Stimulus wiring (phase 12)' do
    it 'uses data-bs-* toggles only and wires "Verify via swimmers" to the verify-team controller' do
      visit(review_teams_path(file_path: source_path, phase2_v2: 1, filter_state: 'none'))

      expect(page).to have_css('[id^="team-card-"]', minimum: 1)
      expect(page).to have_no_css('[data-toggle], [data-target], [onclick], [onchange], [onsubmit]', visible: :all)
      verify_button = first('.verify-team-btn', visible: :all)
      expect(verify_button['data-action']).to eq('verify-team#verify')
      expect(verify_button.ancestor("[data-controller='verify-team']", visible: :all)['data-verify-team-url-value'])
        .to include('/data_fix/verify_team')
      toggle = first('[id^="team-header-"]', visible: :all)
      expect(toggle['data-bs-toggle']).to eq('collapse')
      expect(toggle['data-bs-target']).to start_with('#team-panel-')
      expect(page).to have_css('turbo-frame[id^="team-card-k-"][target="_top"]', minimum: 1)
      expect_no_js_errors
    end
  end

  describe 'step 5 (results): individual-result overwrite candidates' do
    let(:phase5_path) { File.join(work_dir, 'sample-200RA-l4-phase5.json') }
    let(:candidate) do
      { 'id' => 987_654_321, 'selected' => false, 'merge' => false, 'merge_available' => false, 'session_order' => 1,
        'event_code' => '100SL', 'category_code' => 'M25', 'gender_code' => 'M', 'meeting_program_id' => 1, 'swimmer_id' => 1,
        'team_id' => 1, 'swimmer_name' => 'Overwrite Candidate', 'team_name' => 'Overwrite Team', 'timing' => "1'00.00",
        'rank' => 1, 'lap_count' => 0, 'minutes' => 1, 'seconds' => 0, 'hundredths' => 0 }
    end

    before(:each) do
      snapshot = { 'version' => DataFix::IndividualResultOverwriteReconciler::SNAPSHOT_VERSION, 'candidates' => [candidate] }
      File.write(phase5_path, JSON.generate('name' => 'phase5', 'source_file' => File.basename(source_path), 'programs' => [],
                                            '_meta' => { 'individual_result_overwrite' => { 'enabled' => true, 'snapshot' => snapshot } }))
    end

    it 'turns a ticked candidate row red (to be deleted) and muted again when unticked' do
      visit(review_results_path(file_path: source_path, phase5_v2: 1))
      row = "tr[data-candidate-id='#{candidate['id']}']"
      expect(page).to have_css("#{row}.bg-body-tertiary.text-body-secondary")

      find("#{row} input[data-data-fix-overwrite-target='candidate']").click
      expect(page).to have_css("#{row}.bg-danger.text-white")
      expect(page).to have_no_css("#{row}.bg-body-tertiary, #{row}.text-body-secondary")

      find("#{row} input[data-data-fix-overwrite-target='candidate']").click
      expect(page).to have_css("#{row}.bg-body-tertiary.text-body-secondary")
      expect(page).to have_no_css("#{row}.bg-danger, #{row}.text-white")
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
