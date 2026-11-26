# frozen_string_literal: true

require 'rails_helper'

# Smoke journeys 12-15: app shell (sidebar, collapse cookie, offcanvas, status frame, API-offline session).
RSpec.describe 'App shell' do
  let(:admin_user) { prepare_admin_user }

  before(:each) do
    allow(APIProxy).to receive(:ping).and_return(DummyResponse.new(body: { msg: 'OK', version: '7.0' }.to_json))
  end

  after(:each) { Ops::Database.reset_state! }

  def compact_status_pill_ids
    all('turbo-frame#shell-status .app-status-pill').pluck(:id)
  end

  # Shell::StatusPillsComponent: one pill per probe not OK, plus the summary pill counting the OK ones.
  def expect_compact_status_pills
    pills = all('turbo-frame#shell-status .app-status-pill').to_a
    summary = pills.find { |pill| pill[:id] == 'status-pill-all' }
    singles = pills - [summary]
    expect(singles.map { |pill| pill['data-status-level'] }).to all(satisfy { |level| level != 'ok' })
    expect(singles.size + (summary ? summary['data-ok-count'].to_i : 0)).to eq(SystemStatus::Registry::PROBES.size)
  end

  describe 'journey 12: sidebar navigation' do
    before(:each) { sign_in_admin(admin_user) }

    it 'reaches the first item of every sidebar group, highlighting it, and loads the status pills' do
      visit(settings_path)
      expect(page).to have_css('turbo-frame#shell-status .app-status-pill')
      expect_compact_status_pills

      Shell::Navigation.groups.each do |group|
        item = group.items.first
        path = Shell::Navigation.path_for(item)
        within('.app-sidebar') { find("a.nav-link[href=\"#{path}\"]").click }
        expect(page).to have_current_path(path)
        expect(page).to have_css(".app-sidebar a.nav-link.active[href=\"#{path}\"][aria-current=\"page\"]")
        expect(page).to have_css('.app-sidebar a.nav-link.active', count: 1)
      end
      expect_no_js_errors
    end
  end

  describe 'journey 12b: compact status pills' do
    let(:ok_results) do
      SystemStatus::Registry::PROBES.each_index.map do |index|
        SystemStatus::Result.new(key: :"probe#{index}", label: "Probe #{index}", level: :ok, detail: "fine #{index}")
      end
    end

    before(:each) { sign_in_admin(admin_user) }

    it 'folds the probes into one "All OK" pill, listing them in a multi-line tooltip, linking to the dashboard' do
      allow(SystemStatus::Registry).to receive(:results).and_return(ok_results)
      visit(settings_path)
      expect(page).to have_css('turbo-frame#shell-status a#status-pill-all[data-status-summary="all"]', visible: :visible)
      expect(page).to have_css('turbo-frame#shell-status .app-status-pill', count: 1)

      find_by_id('status-pill-all').hover
      expect(page).to have_css('.tooltip.app-status-tooltip', text: 'Probe 0: fine 0')
      expect(page).to have_css('.tooltip.app-status-tooltip', text: "Probe #{ok_results.size - 1}: fine #{ok_results.size - 1}")
      expect(evaluate_script("getComputedStyle(document.querySelector('.app-status-tooltip .tooltip-inner')).whiteSpace"))
        .to eq('pre-line')
      expect_no_js_errors

      find_by_id('status-pill-all').click
      expect(page).to have_current_path(root_path)
      expect(page).to have_css('#dashboard-system')
    end

    it 'shows the probes needing attention one by one, next to an "N OK" pill for the others' do
      results = ok_results.dup
      results[1] = SystemStatus::Result.new(key: :crawler, label: 'Crawler', level: :error, detail: 'Crawler down')
      results[3] = SystemStatus::Result.new(key: :cable, label: 'Live', level: :unknown, detail: 'Never checked')
      allow(SystemStatus::Registry).to receive(:results).and_return(results)
      visit(settings_path)
      expect(page).to have_css('turbo-frame#shell-status .app-status-pill', count: 3)
      expect(page).to have_css('#status-pill-crawler[data-status-level="error"]')
      expect(page).to have_css('#status-pill-cable[data-status-level="unknown"]')
      expect(page).to have_css('#status-pill-all[data-status-summary="rest"] .app-status-summary-label', text: "#{results.size - 2} OK")
      expect(compact_status_pill_ids).to eq(%w[status-pill-crawler status-pill-cable status-pill-all])

      find_by_id('status-pill-all').hover
      expect(page).to have_css('.tooltip.app-status-tooltip', text: 'Probe 0: fine 0')
      expect(page).to have_no_css('.tooltip.app-status-tooltip', text: 'Crawler down')
      expect_no_js_errors
    end
  end

  describe 'journey 13: collapsing the sidebar' do
    before(:each) { sign_in_admin(admin_user) }

    it 'collapses to icons only and keeps the state after a reload, then expands again' do # rubocop:disable RSpec/MultipleExpectations
      visit(settings_path)
      expect(page).to have_css('.app-shell:not(.app-shell--collapsed)')
      expect(page).to have_css('.app-sidebar .app-nav-label', text: I18n.t('dashboard.settings.title'))

      find_by_id('sidebar-toggle').click
      expect(page).to have_css('.app-shell.app-shell--collapsed')
      expect(page).to have_no_css('.app-sidebar .app-nav-label', text: I18n.t('dashboard.settings.title'))
      expect(find_by_id('sidebar-toggle')['aria-expanded']).to eq('false')

      visit(settings_path)
      expect(page).to have_css('.app-shell.app-shell--collapsed')
      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/settings"]')

      find_by_id('sidebar-toggle').click
      expect(page).to have_css('.app-shell:not(.app-shell--collapsed)')
      visit(settings_path)
      expect(page).to have_css('.app-shell:not(.app-shell--collapsed)')
      expect(page).to have_css('.app-sidebar .app-nav-label', text: I18n.t('dashboard.settings.title'))
      expect_no_js_errors
    end
  end

  describe 'journey 14: offcanvas sidebar on a narrow window' do
    before(:each) do
      sign_in_admin(admin_user)
      page.driver.browser.manage.window.resize_to(600, 900)
    end

    after(:each) { page.driver.browser.manage.window.resize_to(1400, 1000) }

    it 'hides the sidebar behind the menu button and navigates from the offcanvas' do
      visit(settings_path)
      expect(page).to have_css('#sidebar-offcanvas-toggle', visible: :visible)
      expect(page).to have_no_css('#app-sidebar', visible: :visible)
      expect(page).to have_no_css('#sidebar-toggle', visible: :visible)

      find_by_id('sidebar-offcanvas-toggle').click
      expect(page).to have_css('#app-sidebar.show', visible: :visible)
      within('#app-sidebar') { click_link(I18n.t('season_board.nav')) }

      expect(page).to have_current_path(season_board_path)
      expect(page).to have_no_css('#app-sidebar', visible: :visible)
      expect(page).to have_no_css('.offcanvas-backdrop')
      expect_no_js_errors
    end
  end

  describe 'journey 15: API-offline session' do
    before(:each) do
      admin_user.update!(jwt: nil)
      allow(APIProxy).to receive(:call).with(hash_including(method: :post, url: 'session'))
                                       .and_return(unreachable_api_result)
      allow(APIProxy).to receive_messages(ping: unreachable_api_result)
    end

    it 'shows the unavailable areas disabled and a working Settings page (API label form included)' do # rubocop:disable RSpec/MultipleExpectations
      sign_in_through_form(admin_user)
      expect(page).to have_current_path(settings_path)

      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/settings"]')
      offline_ok = Shell::Navigation::ITEMS.count { |item| item.sidebar? && item.offline_ok? } # (Dashboard, Settings, Remote writes)
      expect(page).to have_css('.app-sidebar a.nav-link.disabled[aria-disabled="true"]',
                               count: Shell::Navigation::ITEMS.count(&:sidebar?) - offline_ok)
      expect(page).to have_css('.app-sidebar a.nav-link:not(.disabled)', count: offline_ok)
      expect(page).to have_css('#api-target-badge[data-api-reachability="unreachable"]')
      expect(page).to have_css('turbo-frame#shell-status #status-pill-api[data-status-level="unknown"]')
      expect(page).to have_no_css('#api-offline-banner')

      fill_in('api-target-label', with: 'Broken local API')
      click_button('btn-save-api-target-label')
      expect(page).to have_current_path(settings_path)
      expect(page).to have_css('#api-target-badge .app-api-label', text: 'Broken local API')
      expect(page).to have_field('api-target-label', with: 'Broken local API')
      expect_no_js_errors
    end
  end
end
