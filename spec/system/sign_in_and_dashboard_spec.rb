# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'version'

# Smoke journeys 1-4 (sign-in, dashboard, app shell user menu, tooltips & API-offline session) and 16-17
# (dashboard live reload, inbox action).
RSpec.describe 'Sign-in & dashboard' do
  let(:admin_user) { prepare_admin_user }
  let(:data_dir) { Pathname.new(Dir.mktmpdir('dashboard-system')) }
  let(:api_url) { Shell::APITarget.configured_url }
  let(:kpi_values) { { 'api_uses' => 11, 'import_queues' => 5, 'issues' => 0, 'users' => 3 } }

  before(:each) do
    # (an empty crawler data folder & no FIN watcher state: a deterministic, empty Season board)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_dir)
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path])
    fetched_at = 5.minutes.ago.iso8601
    Ops::Snapshot.write!(KpiRefreshJob.key_for(api_url), { 'url' => api_url, 'status' => 'ok', 'values' => kpi_values,
                                                           'fetched_at' => kpi_values.transform_values { fetched_at }, 'errors' => {} })
  end

  after(:each) do
    FileUtils.remove_entry(data_dir)
    FileUtils.rm_f([FedernuotoWatch::StateStore.default_path, SeasonBoard::ActivityLog.default_path])
  end

  describe 'journey 1: signing-in through the form' do
    it 'lands on the dashboard: the four KPI tiles from the counters snapshot and every zone loaded' do
      sign_in_through_form(admin_user)

      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/"]')
      expect(page).to have_css('#user-menu')
      {
        '#kpi-tile-api-uses[href="/stats"]' => '11',
        '#kpi-tile-import-queues[href="/api_import_queues"]' => '5',
        '#kpi-tile-issues[href="/api_issues"]' => '0',
        '#kpi-tile-users[href="/api_users"]' => '3'
      }.each do |selector, total|
        expect(page).to have_css("#{selector} .kpi-value", text: total)
      end
      expect(page).to have_css('#dashboard-needs-you #inbox-items, #dashboard-needs-you #inbox-empty')
      expect(page).to have_css('#dashboard-in-progress #in-progress')
      expect(page).to have_css('#dashboard-season-progress #season-progress')
      expect(page).to have_css('#dashboard-system .dashboard-status-row', count: SystemStatus::Registry::PROBES.size)
      expect(page).to have_css('#dashboard-activity #activity-feed')
      expect_no_js_errors
    end
  end

  describe 'journey 2: sidebar to Settings, user menu & log out' do
    before(:each) { sign_in_through_form(admin_user) }

    it 'navigates to Settings from the sidebar, opens the user menu and logs out' do
      within('.app-sidebar') { click_link(I18n.t('dashboard.settings.title')) }
      expect(page).to have_current_path(settings_path)
      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/settings"]')

      expect(page).to have_no_css('.dropdown-menu.show')
      find_by_id('user-menu').click
      expect(page).to have_css('.app-user-menu .dropdown-menu.show #href-locale-switch')
      expect(page).to have_css('.dropdown-menu.show #app-version', text: Version::FULL)

      within('.app-user-menu .dropdown-menu.show') { click_link(I18n.t('home.log_out')) }
      expect(page).to have_current_path(new_user_session_path)
      expect(page).to have_css('#login-btn')
      expect_no_js_errors
    end
  end

  describe 'journey 3: help icon tooltips' do
    before(:each) { sign_in_through_form(admin_user) }

    it 'shows a .tooltip when hovering the "Needs you" help icon' do
      # (the zones above it must be loaded first, or the icon moves away from under the pointer)
      expect(page).to have_css('#kpi-strip')
      expect(page).to have_css('#dashboard-needs-you #inbox-items, #dashboard-needs-you #inbox-empty')
      expect(page).to have_css('#dashboard-needs-you-card .fa-circle-question[data-bs-toggle="tooltip"]')
      expect(page).to have_no_css('.tooltip')
      find('#dashboard-needs-you-card .fa-circle-question').hover
      expect(page).to have_css('.tooltip', text: I18n.t('dashboard.zones.needs_you_help'))
      expect_no_js_errors
    end
  end

  describe 'journey 4: API-offline sign-in' do
    before(:each) do
      admin_user.update!(jwt: nil)
      allow(APIProxy).to receive(:call)
        .with(hash_including(method: :post, url: 'session'))
        .and_return(unreachable_api_result)
      allow(APIProxy).to receive_messages(ping: unreachable_api_result)
    end

    it 'lands on Settings with the help box; the dashboard banner outlives the transient flash, the inbox shows the blocker' do
      sign_in_through_form(admin_user)

      expect(page).to have_current_path(settings_path)
      expect(page).to have_css('#api-offline-help')
      # The transient (non-sticky) sign-in flash is a toast that auto-hides after 5 seconds
      # (errors and sticky alerts never do) and gets removed from the DOM:
      expect(page).to have_no_css('.toast.flash-alert:not(.flash-sticky)', wait: 12)

      visit(root_path)
      expect(page).to have_css('#api-offline-banner')
      expect(page).to have_css('#dashboard-needs-you li.inbox-item[data-inbox-key="blocker:api_offline"]')
      sleep(4)
      expect(page).to have_css('#api-offline-banner')
      expect(page).to have_no_css('.toast.flash-alert:not(.flash-sticky)')
      expect_no_js_errors
    end
  end

  describe 'journey 16: live reload of the dashboard zones' do
    before(:each) { sign_in_through_form(admin_user) }

    it 'reloads the zones on an app notification (e.g. the Season board ping)' do
      expect(page).to have_css('#dashboard-needs-you #inbox-items, #dashboard-needs-you #inbox-empty')
      expect(page).to have_no_css('[data-inbox-key="fin_change"]')

      FedernuotoWatch::StateStore.new.update do |state|
        state.merge('change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'name' => 'Brand new meeting' }] })
      end
      page.execute_script("document.dispatchEvent(new CustomEvent('app-notification', { detail: { dom_id: 'season-board-ping', html: '' } }))")

      expect(page).to have_css('#dashboard-needs-you [data-inbox-key="fin_change"]', text: 'Brand new meeting')
      expect_no_js_errors
    end
  end

  describe 'journey 17: one inbox action' do
    before(:each) { sign_in_through_form(admin_user) }

    it 'opens the remote writes page from the DB sync warning (remote-only writes)' do
      FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
      visit(root_path)
      within('#dashboard-needs-you [data-inbox-key="drift_amber"]') { click_link(I18n.t('inbox.drift.review')) }
      expect(page).to have_current_path(remote_writes_path)
      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/remote_writes"]')
      expect_no_js_errors
    end
  end
end
