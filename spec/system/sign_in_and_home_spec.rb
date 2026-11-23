# frozen_string_literal: true

require 'rails_helper'
require 'version'

# Smoke journeys 1-4: sign-in, home dashboard, app shell user menu, tooltips & API-offline session.
RSpec.describe 'Sign-in & home dashboard' do
  let(:admin_user) { prepare_admin_user }
  let(:kpi_totals) { { 'api_daily_uses' => 11, 'import_queues' => 5, 'issues' => 7, 'users' => 3 } }

  before(:each) do
    kpi_totals.each do |endpoint, total|
      allow(APIProxy).to receive(:call)
        .with(method: :get, url: endpoint, jwt: admin_user.jwt)
        .and_return(DummyResponse.new(body: (1..total).to_a))
    end
  end

  describe 'journey 1: signing-in through the form' do
    it 'lands on home showing the four KPI cards with the stubbed totals' do
      sign_in_through_form(admin_user)

      expect(page).to have_css('.app-sidebar a.nav-link.active[href="/"]')
      expect(page).to have_css('#user-menu')
      expect(page).to have_css('.card', minimum: 4)
      {
        'a[href="/stats"]' => '11',
        'a[href="/api_import_queues"]' => '5',
        'a[href="/api_issues"]' => '7',
        'a[href="/api_users"]' => '3'
      }.each do |selector, total|
        expect(page).to have_css("#{selector}.card h1.display-4", text: total)
      end
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

    it 'shows a .tooltip when hovering a help icon' do
      expect(page).to have_css('.fa-question-circle[data-toggle="tooltip"]', minimum: 1)
      expect(page).to have_no_css('.tooltip')
      first('.fa-question-circle[data-toggle="tooltip"]').hover
      expect(page).to have_css('.tooltip')
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

    it 'lands on Settings with the help box; the home banner outlives the transient flash' do
      sign_in_through_form(admin_user)

      expect(page).to have_current_path(settings_path)
      expect(page).to have_css('#api-offline-help')
      # The transient (non-sticky) sign-in flash is a toast that auto-hides after 5 seconds
      # (errors and sticky alerts never do) and gets removed from the DOM:
      expect(page).to have_no_css('.toast.flash-alert:not(.flash-sticky)', wait: 12)

      visit(root_path)
      expect(page).to have_css('#api-offline-banner')
      sleep(4)
      expect(page).to have_css('#api-offline-banner')
      expect(page).to have_no_css('.toast.flash-alert:not(.flash-sticky)')
      expect_no_js_errors
    end
  end
end
