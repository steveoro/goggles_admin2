# frozen_string_literal: true

require 'rails_helper'

# Switches (0.10.101, Switch::ToggleFormComponent + toggle_submit_controller.js): the automation kill switches and the
# row "Auto-prepare" switch answer with turbo streams (the board keeps its filter chip and its open <details>, no full
# reload); the 'operations.enabled' switch of the dashboard hides / shows the Fix buttons.
# (The Builder is stubbed, as in spec/system/season_board_spec.rb; the row hold is read back from the ops DB.)
RSpec.describe 'Switches' do
  def build_row(overrides = {})
    defaults = {
      fin_event_id: '150091', key: 'k', date_text: '08/11', first_date: Date.new(2026, 11, 8), last_date: Date.new(2026, 11, 8),
      year: '2026', name: 'Trofeo Test', place: 'Roma', url: 'https://www.federnuoto.it/#/risultati/150091:trofeo-test', info: nil,
      calendar_id: nil, meeting_id: nil, meeting_description: nil, meeting_header_date: nil, mir_count: 0, mrr_count: 0,
      results_acquired: false, state: :link_not_crawled, state_detail: {}, next_action: nil,
      activity: { crawl: nil, extract: nil }, busy: false, flags: [], calendar: nil, disk_entry: nil
    }
    SeasonBoard::Row.new(**defaults, **overrides)
  end

  def action(kind, fin_id, **params)
    SeasonBoard::NextAction.new(kind:, params: { fin_event_id: fin_id }.merge(params))
  end

  # (a full page load drops this marker)
  def mark_page = page.execute_script('window.__switchesSpecMarker = "kept"')

  def expect_same_page = expect(page.evaluate_script('window.__switchesSpecMarker')).to eq('kept')

  def focused_id = page.evaluate_script('document.activeElement && document.activeElement.id')

  # [checked, disabled] of the switch in the Turbo cache snapshot of the page whose URL includes +url_part+.
  def cached_switch_state(url_part, switch_id)
    page.evaluate_script(<<~JS)
      (() => {
        const cache = window.Turbo.session.view.snapshotCache
        const key = Object.keys(cache.snapshots).find((url) => url.includes('#{url_part}'))
        if (!key) return 'no snapshot'
        const input = cache.snapshots[key].element.querySelector('##{switch_id}')
        return input ? [input.checked, input.disabled] : 'no switch'
      })()
    JS
  end

  let(:season) { GogglesDb::Season.first }
  let(:rows) do
    [
      build_row(fin_event_id: '1', name: 'To crawl', state: :link_not_crawled, next_action: action(:crawl, '1', url: 'u1'),
                url: 'https://fin.example/1'),
      build_row(fin_event_id: '3', name: 'To review', state: :results_ready,
                next_action: action(:review_results, '3', file_path: '/d/262/r.json'), url: 'https://fin.example/3'),
      build_row(fin_event_id: '4', name: 'Also to review', state: :results_ready,
                next_action: action(:review_results, '4', file_path: '/d/262/s.json'), url: 'https://fin.example/4')
    ]
  end
  let(:result) do
    SeasonBoard::Builder::Result.new(season:, rows:, orphans: [], unmatched_sources: [], warnings: [], active_activities: [],
                                     snapshot_checked_at: Time.zone.local(2026, 11, 12, 9, 30))
  end

  before(:each) do
    allow(SeasonBoard::Builder).to receive(:latest_season).and_return(season)
    allow(SeasonBoard::Builder).to receive(:new) do
      held_bases = Ops::PipelineSource.where(season_id: 262, auto_prepare: false).pluck(:base)
      built = rows.map do |row|
        base = File.basename(row.next_action&.params&.dig(:file_path).to_s, '.json')
        held_bases.include?(base) ? row.with(flags: [:prepare_held]) : row
      end
      instance_double(SeasonBoard::Builder, call: result.with(rows: built))
    end
    sign_in_admin(prepare_admin_user)
  end

  describe 'Season board' do
    before(:each) { visit(season_board_path) }

    it 'flips an automation switch in place: the chip stays selected, the <details> stays open, the badge changes' do # rubocop:disable RSpec/MultipleExpectations
      find('a[data-state-chip="results_ready"]').click
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 2)
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      mark_page

      find('#season-board-automation summary').click
      expect(page).to have_css('#season-board-automation[open]')
      expect(page).to have_css('#season-board-automation-badge[data-automation-paused="false"]')
      expect(page).to have_field('automation-switch-season_board-auto_prepare', checked: true)
      expect(page).to have_no_css('#btn-season-board-prepare-all[disabled]')

      find_by_id('automation-switch-season_board-auto_prepare').click
      expect(page).to have_css('#season-board-automation-badge[data-automation-paused="true"]')
      expect(page).to have_css('[data-automation-switch="auto_prepare"][data-automation-state="off"]')
      expect(page).to have_field('automation-switch-season_board-auto_prepare', checked: false, disabled: false)
      expect(page).to have_css('#btn-season-board-prepare-all[disabled]')
      expect(page).to have_css('#flash-messages-container .toast')
      expect(page).to have_css('#season-board-automation[open]')
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 2)
      expect(DataFix::Automation.enabled?(:auto_prepare)).to be false
      # (the keyboard focus is back on the new switch)
      expect(focused_id).to eq('automation-switch-season_board-auto_prepare')
      expect_same_page

      find_by_id('automation-switch-season_board-auto_prepare').click
      expect(page).to have_css('#season-board-automation-badge[data-automation-paused="false"]')
      expect(page).to have_css('#season-board-automation[open]')
      expect_same_page
      expect_no_js_errors
    end

    it 'flips the "Auto-prepare" switch of a row: the row updates in place, the filter kept' do # rubocop:disable RSpec/MultipleExpectations
      find('a[data-state-chip="results_ready"]').click
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      mark_page
      expect(page).to have_field('season-board-hold-3', checked: true)
      expect(page).to have_no_css('#season-board-row-3 [data-flag="prepare_held"]')

      find_by_id('season-board-hold-3').click
      expect(page).to have_css('#season-board-row-3 [data-flag="prepare_held"]')
      expect(page).to have_field('season-board-hold-3', checked: false, disabled: false)
      expect(page).to have_field('season-board-hold-4', checked: true)
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 2)
      expect(Ops::PipelineSource.find_by(season_id: 262, base: 'r').auto_prepare).to be false
      expect_same_page

      find_by_id('season-board-hold-3').click
      expect(page).to have_no_css('#season-board-row-3 [data-flag="prepare_held"]')
      expect(page).to have_field('season-board-hold-3', checked: true)
      expect_same_page
      expect_no_js_errors
    end

    it 'puts the switch back (enabled again) when the request fails' do
      find('#season-board-automation summary').click
      expect(page).to have_field('automation-switch-season_board-auto_extract', checked: true)
      # (every request fails at the network level from now on)
      page.execute_script("window.fetch = () => Promise.reject(new TypeError('offline (spec)'))")

      find_by_id('automation-switch-season_board-auto_extract').click
      expect(page).to have_field('automation-switch-season_board-auto_extract', checked: true, disabled: false)
      expect(page).to have_no_css('form.switch-toggle-form[aria-busy]')
      expect(DataFix::Automation.enabled?(:auto_extract)).to be true
      # (Turbo logs the network error to the console)
      expect(severe_js_log_messages.join("\n")).to include('offline (spec)')
    end

    it 'puts the switch back when the answer is an error status' do
      find('#season-board-automation summary').click
      page.execute_script(<<~JS)
        window.fetch = () => Promise.resolve(new Response('boom', { status: 500, headers: { 'Content-Type': 'text/plain' } }))
      JS
      find_by_id('automation-switch-season_board-auto_extract').click
      expect(page).to have_field('automation-switch-season_board-auto_extract', checked: true, disabled: false)
      expect(page).to have_no_css('form.switch-toggle-form[aria-busy]')
      expect(focused_id).to eq('automation-switch-season_board-auto_extract')
      expect(DataFix::Automation.enabled?(:auto_extract)).to be true
    end

    it 'never restores a stuck or unstored switch from the Turbo cache (Back while a request was in flight)' do
      expect(page).to have_field('season-board-hold-3', checked: true)
      # (the request never answers: the switch stays flipped and disabled)
      page.execute_script('window.__realFetch = window.fetch; window.fetch = () => new Promise(() => {})')
      find_by_id('season-board-hold-3').click
      expect(page).to have_field('season-board-hold-3', checked: false, disabled: true)
      page.execute_script('window.fetch = window.__realFetch')

      within('.app-sidebar') { find("a[href='#{operations_path}']").click }
      expect(page).to have_current_path(operations_path)
      # (the turbo:before-cache reset: the snapshot of the board holds the stored position, enabled)
      expect(cached_switch_state('season_board', 'season-board-hold-3')).to eq([true, false])

      page.go_back
      expect(page).to have_current_path(season_board_path)
      expect(page).to have_field('season-board-hold-3', checked: true, disabled: false)
      expect(Ops::PipelineSource.where(auto_prepare: false)).to be_empty
    end

    it 'lands on the last chosen chip from the sidebar link' do
      find('a[data-state-chip="results_ready"]').click
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      within('.app-sidebar') { find("a[href='#{season_board_path}']").click }
      expect(page).to have_current_path(season_board_path)
      expect(page).to have_css('a[data-state-chip="results_ready"][data-chip-selected="true"]')
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 2)

      find_by_id('season-board-chip-all').click
      expect(page).to have_css('#season-board-chip-all[data-chip-selected="true"]')
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 3)
      expect_no_js_errors
    end
  end

  describe 'dashboard: the operations switch' do
    let(:finding) do
      FactoryBot.create(:ops_health_finding, season_id: season.id,
                                             payload: { 'cancel' => { 'meeting_id' => 7 }, 'meeting_id' => 7, 'description' => 'Trofeo',
                                                        'title_args' => { 'id' => 7, 'date' => '-', 'description' => 'x' } })
    end
    let(:fix_button) { 'a[data-operation-key="meeting.set_cancelled"]' }

    it 'hides the Fix buttons when turned off (in place), and shows them again when turned back on from /operations' do # rubocop:disable RSpec/MultipleExpectations
      visit(health_finding_path(finding))
      expect(page).to have_css(fix_button)

      visit(root_path)
      expect(page).to have_field('operations-switch-input-dashboard', checked: true)
      mark_page
      find_by_id('operations-switch-input-dashboard').click
      expect(page).to have_css('#operations-switch-dashboard[data-operations-enabled="false"]')
      expect(page).to have_field('operations-switch-input-dashboard', checked: false, disabled: false)
      expect(page).to have_css('#flash-messages-container .toast')
      expect_same_page
      expect(Maintenance.enabled?).to be false

      visit(health_finding_path(finding))
      expect(page).to have_css('#health-finding-actions')
      expect(page).to have_no_css(fix_button)

      visit(operations_path)
      expect(page).to have_css('#operations-disabled')
      find_by_id('operations-switch-input-operations').click
      expect(page).to have_no_css('#operations-disabled')
      expect(page).to have_field('operations-switch-input-operations', checked: true)

      visit(health_finding_path(finding))
      expect(page).to have_css(fix_button)
      expect_no_js_errors
    end
  end
end
