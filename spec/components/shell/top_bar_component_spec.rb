# frozen_string_literal: true

require 'rails_helper'
require 'version'

RSpec.describe Shell::TopBarComponent, type: :component do
  subject(:html) { render_inline(described_class.new(api_target:, offline: offline_info.present?, user:)) }

  let(:user) { FactoryBot.build(:user) }
  let(:api_url) { 'https://master-goggles.org:447' }
  let(:offline_info) { nil }
  let(:api_target) { Shell::APITarget.new(url: api_url, offline_info:) }

  before(:each) do
    allow(APIProxy).to receive(:call)
    allow(APIProxy).to receive(:ping)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'renders both sidebar toggles' do
    expect(html.at_css('button#sidebar-offcanvas-toggle[data-bs-toggle="offcanvas"][data-bs-target="#app-sidebar"]')).to be_present
    expect(html.at_css('button#sidebar-toggle[data-action="shell#toggleSidebar"]')['aria-expanded']).to eq('true')
  end

  it 'renders the API target badge and the lazy status frame' do
    expect(html.at_css('#api-target-badge')).to be_present
    frame = html.at_css('turbo-frame#shell-status')
    expect(frame['src']).to eq('/shell/status')
    expect(frame['loading']).to eq('lazy')
  end

  it 'renders the theme toggle wired to the theme controller' do
    button = html.at_css('#theme-toggle')
    expect(button['data-action']).to eq('theme#toggle')
    expect(button.ancestors('[data-controller~="theme"]')).not_to be_empty
  end

  it 'renders the user menu' do
    expect(html.at_css('.dropdown #user-menu[data-bs-toggle="dropdown"]')).to be_present
    expect(html.at_css('#href-locale-switch')).to be_present
    expect(html.text).to include(Version::FULL)
  end

  it 'makes no API call while rendering' do
    html
    expect(APIProxy).not_to have_received(:call)
    expect(APIProxy).not_to have_received(:ping)
  end

  it 'renders the optional search slot' do
    html = render_inline(described_class.new(api_target:, user:)) { |bar| bar.with_search { 'SEARCH-SLOT' } }
    expect(html.at_css('.app-topbar-search').text).to include('SEARCH-SLOT')
  end

  context 'with an API-offline session' do
    let(:offline_info) { { 'url' => api_url, 'reason' => 'API unreachable (x): refused', 'at' => Time.current.iso8601 } }

    it 'never prints the REMOTE marker nor the API-offline banner, and makes no API call' do
      expect(html.to_html).not_to include('REMOTE ')
      expect(html.to_html).not_to include('api-offline-banner')
      expect(html.at_css('#api-target-badge')['data-api-reachability']).to eq('unreachable')
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
    end
  end

  context 'with the ops DB missing' do
    before(:each) { allow(Ops::Database).to receive(:state).and_return(:missing) }

    it 'still renders, with an unknown reachability' do
      expect(html.at_css('#api-target-badge')['data-api-reachability']).to eq('unknown')
    end
  end
end
