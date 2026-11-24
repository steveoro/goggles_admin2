# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::SidebarComponent, type: :component do
  subject(:html) { render_inline(described_class.new(current:, offline:)) }

  let(:current) { Shell::Navigation.find(:teams) }
  let(:offline) { false }

  it 'renders the offcanvas sidebar with every non-empty group' do
    expect(html.at_css('aside.app-sidebar.offcanvas-lg.offcanvas-start#app-sidebar')).to be_present
    expect(html.css('[data-nav-group]').pluck('data-nav-group')).to eq(%w[dashboard import data_quality entities reports support system])
  end

  it 'links every sidebar item' do
    hrefs = html.css('.app-sidebar a.nav-link').pluck('href')
    expect(hrefs).to include('/', '/season_board', '/sources/results', '/api_teams', '/settings', '/best_results/goggles_cup_preview')
    expect(hrefs.size).to eq(Shell::Navigation::ITEMS.count(&:sidebar?))
  end

  it 'highlights only the current item' do
    active = html.css('.app-sidebar a.nav-link.active')
    expect(active.size).to eq(1)
    expect(active.first['href']).to eq('/api_teams')
    expect(active.first['aria-current']).to eq('page')
  end

  context 'with a contextual item (Data-Fix)' do
    let(:current) { Shell::Navigation.find(:data_fix) }

    it 'highlights its sidebar parent (Sources)' do
      expect(html.css('.app-sidebar a.nav-link.active').pluck('href')).to eq(['/sources/results'])
    end
  end

  context 'without a current item' do
    let(:current) { nil }

    it 'highlights nothing' do
      expect(html.css('.app-sidebar a.nav-link.active')).to be_empty
    end
  end

  context 'with an API-offline session' do
    let(:offline) { true }

    it 'disables the items that need the API, with an explaining tooltip' do
      disabled = html.css('.app-sidebar a.nav-link.disabled')
      expect(disabled.size).to eq(Shell::Navigation::ITEMS.count { |item| item.sidebar? && !item.offline_ok? })
      expect(disabled.pluck('aria-disabled').uniq).to eq(['true'])
      wrapper = disabled.first.parent
      expect(wrapper['data-bs-toggle']).to eq('tooltip')
      expect(wrapper['data-bs-title']).to eq(I18n.t('shell.nav.offline_disabled'))
    end

    it 'keeps Dashboard, Settings, Remote writes, the Outbox and DB sync (local data only) enabled' do
      enabled = html.css('.app-sidebar a.nav-link:not(.disabled)').pluck('href')
      expect(enabled).to contain_exactly('/', '/settings', '/remote_writes', '/outbox', '/db_sync')
    end
  end
end
