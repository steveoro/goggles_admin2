# frozen_string_literal: true

require 'rails_helper'

# Command palette (phase 15): the local search endpoint and its mounting in the application layout.
RSpec.describe 'Command palette' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:html) { response.parsed_body }
  let(:session_index) { instance_double(DataFix::SessionIndex, rows: []) }

  before(:each) do
    allow(APIProxy).to receive_messages(call: DummyResponse.new(body: '{}'), ping: DummyResponse.new(body: '{}'))
    allow(DataFix::SessionIndex).to receive(:new).and_return(session_index)
  end

  after(:each) { Ops::Database.reset_state! }

  describe 'GET /palette/search' do
    it 'answers 401 to an anonymous visitor (a JSON endpoint)' do
      get(palette_search_path(q: 'abc'))
      expect(response).to have_http_status(:unauthorized)
    end

    context 'with a signed-in admin' do
      before(:each) { sign_in_admin(admin_user) }

      it 'answers the local matches as JSON, without calling the API' do
        FactoryBot.create(:team, name: 'Zqpalette Swim Team')
        get(palette_search_path(q: 'zqpalette'))
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq('application/json')
        results = response.parsed_body['results']
        expect(results.pluck('kind')).to eq(['team'])
        expect(results.first).to include('label' => 'Zqpalette Swim Team', 'kind_label' => I18n.t('shell.palette.kinds.team'))
        expect(APIProxy).not_to have_received(:call)
      end

      it 'answers an empty list to a too-short query' do
        get(palette_search_path(q: 'z'))
        expect(response.parsed_body).to eq('results' => [])
      end
    end
  end

  describe 'layout' do
    it 'is not rendered on the sign-in page' do
      get(new_user_session_path)
      expect(html.at_css('#command-palette, #palette-trigger')).to be_nil
    end

    context 'with a signed-in admin' do
      before(:each) do
        sign_in_admin(admin_user)
        get(settings_path)
      end

      it 'renders the modal at the body level with the navigation entries and the search URL' do
        palette = html.at_css('body > #command-palette.modal[data-controller="palette"]')
        expect(palette).to be_present
        expect(palette['class']).not_to include('fade')
        expect(palette['data-action']).to include('keydown@window->palette#hotkey')
        expect(palette['data-palette-search-url-value']).to eq(palette_search_path)
        entries = JSON.parse(palette['data-palette-entries-value'])
        expect(entries.pluck('key')).to eq(Shell::Navigation::ITEMS.map { |item| item.key.to_s })
        expect(palette.at_css('input#command-palette-input[role="combobox"][aria-controls="command-palette-results"]')).to be_present
        expect(palette.at_css('#command-palette-results[role="listbox"]')).to be_present
      end

      it 'renders the trigger in the top bar search slot' do
        trigger = html.at_css('header.app-topbar .app-topbar-search button#palette-trigger')
        expect(trigger['data-bs-toggle']).to eq('modal')
        expect(trigger['data-bs-target']).to eq('#command-palette')
        expect(trigger['aria-keyshortcuts']).to eq('Control+K Meta+K')
      end
    end

    context 'with an API-offline session' do
      before(:each) do
        sign_in_api_offline(admin_user)
        get(settings_path)
      end

      it 'lists only the offline pages and searches nothing else' do
        palette = html.at_css('#command-palette')
        expect(palette['data-palette-search-url-value']).to eq('')
        keys = JSON.parse(palette['data-palette-entries-value']).pluck('key')
        expect(keys).to match_array(Shell::Navigation::ITEMS.select(&:offline_ok?).map { |item| item.key.to_s })
        expect(palette.at_css('#command-palette-status').text).to include(I18n.t('shell.palette.offline'))
      end
    end
  end
end
