# frozen_string_literal: true

require 'rails_helper'

# Application shell rendered by layouts/application (sidebar, top bar, sticky alerts, page header).
RSpec.describe 'Application shell' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:html) { response.parsed_body }
  let(:board_result) do
    SeasonBoard::Builder::Result.new(season: GogglesDb::Season.last, rows: [], orphans: [], unmatched_sources: [],
                                     snapshot_checked_at: nil, warnings: [], active_activities: [])
  end

  before(:each) do
    allow(APIProxy).to receive(:call)
    allow(APIProxy).to receive(:ping)
    builder = instance_double(SeasonBoard::Builder, call: board_result)
    allow(SeasonBoard::Builder).to receive_messages(latest_season: GogglesDb::Season.last, new: builder)
  end

  after(:each) { Ops::Database.reset_state! }

  context 'with an anonymous visitor' do
    it 'renders the sign-in page without the shell' do
      get(new_user_session_path)
      expect(html.at_css('main.app-auth #login-box')).to be_present
      expect(html.at_css('.app-shell, .app-sidebar, .app-topbar')).to be_nil
      expect(html.at_css('#flash-messages-container')).to be_present
    end
  end

  context 'with a signed-in admin (a page with no API call of its own)' do
    before(:each) { sign_in_admin(admin_user) }

    it 'renders sidebar, top bar, sticky alerts and content, without calling the API' do
      get(season_board_path)
      expect(response).to have_http_status(:success)
      expect(html.at_css('.app-shell > aside.app-sidebar#app-sidebar')).to be_present
      expect(html.at_css('.app-shell .app-main > header.app-topbar.sticky-top #api-target-badge')).to be_present
      expect(html.at_css('.app-main > #notify > #sticky-alerts')).to be_present
      expect(html.at_css('.app-main > main.app-content#content[data-page="season_board"]')).to be_present
      expect(html.at_css('turbo-frame#shell-status[loading="lazy"]')['src']).to eq(shell_status_path)
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
    end

    it 'keeps the PDF pages loading indicator (hidden)' do
      get(season_board_path)
      expect(html.at_css('body > #loading-indicator.d-none')).to be_present
    end

    it 'renders the expanded sidebar by default' do
      get(season_board_path)
      expect(html.at_css('.app-shell')['class']).not_to include('app-shell--collapsed')
      expect(html.at_css('#sidebar-toggle')['aria-expanded']).to eq('true')
    end

    it "renders the collapsed sidebar from the 'sidebar' cookie" do
      cookies[:sidebar] = 'collapsed'
      get(season_board_path)
      expect(html.at_css('.app-shell')['class']).to include('app-shell--collapsed')
      expect(html.at_css('#sidebar-toggle')['aria-expanded']).to eq('false')
    end

    it 'puts the page title before the app name in <title>' do
      get(best_50m_results_path)
      expect(html.at('title').text).to eq("#{I18n.t('best_results.best_50m.title')} · #{I18n.t('shell.brand')}")
      get(season_board_path)
      expect(html.at('title').text).to end_with(I18n.t('shell.brand'))
    end

    it 'shows the operator label of the current API URL in the top bar' do
      Shell::APITarget.store_label!(APIProxy.configured_base_url, 'My local copy')
      get(season_board_path)
      expect(html.at_css('#api-target-badge .app-api-label').text).to eq('My local copy')
    end

    it 'renders the page header of a grid page (title, count, breadcrumbs)' do
      allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: '[]'))
      get(api_teams_path)
      header = html.at_css('.app-content header.app-page-header')
      expect(header.at_css('.app-page-title').text).to eq(I18n.t('dashboard.teams.title'))
      expect(header.at_css('.app-page-count').text).to eq(I18n.t('dashboard.n_total_rows', tot: 0))
      expect(header.css('.breadcrumb-item').map { |li| li.text.strip })
        .to eq([I18n.t('shell.groups.entities'), I18n.t('dashboard.teams.title')])
    end

    it 'still renders with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      get(season_board_path)
      expect(response).to have_http_status(:success)
      expect(html.at_css('#sticky-alerts #ops-setup-notice')).to be_present
      expect(html.at_css('#api-target-badge')['data-api-reachability']).to eq('unknown')
    end
  end

  context 'with an API-offline session' do
    before(:each) do
      sign_in_api_offline(admin_user)
      # (neither the dashboard nor the shell call the API: see dashboard_controller_spec and the component specs)
      allow(APIProxy).to receive_messages(call: unreachable_api_result, ping: unreachable_api_result)
    end

    it 'renders the shell with the unavailable areas disabled' do
      get(root_path)
      expect(response).to have_http_status(:success)
      enabled = html.css('.app-sidebar a.nav-link:not(.disabled)').pluck('href')
      expect(enabled).to contain_exactly(root_path, settings_path, remote_writes_path)
      expect(html.css('.app-sidebar a.nav-link.disabled[aria-disabled="true"]')).not_to be_empty
      expect(html.at_css('#api-target-badge')['data-api-reachability']).to eq('unreachable')
      expect(html.at_css('#sticky-alerts #api-offline-banner')).to be_present
      expect(html.at_css('.app-topbar').to_html).not_to include('api-offline-banner', 'REMOTE ')
    end

    it 'keeps Settings free of the API-offline banner' do
      get(settings_path)
      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('api-offline-banner')
      expect(html.css('.app-sidebar a.active').pluck('href')).to eq([settings_path])
    end
  end
end
