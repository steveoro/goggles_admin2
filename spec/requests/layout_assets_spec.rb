# frozen_string_literal: true

require 'rails_helper'
require 'version'

# The application layout links only vendored assets (Bootstrap 5.3, Font Awesome 6, tom-select theme):
# no jQuery, no Bootstrap 4 and nothing from a CDN, so the app renders with no network access.
RSpec.describe 'Layout assets' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:html) { response.parsed_body }
  let(:head) { html.at('head') }
  let(:local_modules) { %w[bootstrap @popperjs/core bs4_compat tom-select chart.js/auto] }
  let(:asset_urls) { head.css('link[href]').pluck('href') + head.css('script[src]').pluck('src') }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive_messages(
      call: DummyResponse.new(body: {}.to_json),
      ping: DummyResponse.new(body: { msg: 'OK', version: Version::FULL }.to_json)
    )
  end

  { 'home#index' => :root_path, 'settings#index' => :settings_path }.each do |action, path_helper|
    context "when rendering #{action}" do
      before(:each) { get(public_send(path_helper)) }

      it 'is successful' do
        expect(response).to have_http_status(:success)
      end

      it 'does not load jQuery, Bootstrap 4 or anything from a CDN' do
        expect(head.to_html).not_to match(/jquery/i)
        expect(head.to_html).not_to include('bootstrap@4')
        expect(head.to_html).not_to include('bootstrap.bundle')
        expect(head.to_html).not_to match(/cdn\.jsdelivr|cdnjs/)
        expect(asset_urls).to all(start_with('/'))
      end

      it 'links the vendored Bootstrap 5, Font Awesome & tom-select stylesheets before the application one' do
        stylesheets = head.css('link[rel="stylesheet"]').pluck('href')
        expected = %w[bootstrap/bootstrap.min fontawesome/css/all.min fontawesome/css/v4-shims.min
                      tom-select/tom-select.bootstrap5.min application]
        indexes = expected.map { |name| stylesheets.index { |href| href.start_with?("/assets/#{name}-") } }
        expect(indexes).to all(be_present)
        expect(indexes).to eq(indexes.sort)
      end

      it 'maps Bootstrap & the BS4 compatibility shim to local modules' do
        importmap = JSON.parse(head.at('script[type="importmap"]').text)['imports']
        local_modules.each do |name|
          expect(importmap[name]).to start_with('/assets/')
        end
      end

      it 'sets the light Bootstrap color mode and the tooltips controller by default' do
        expect(html.at('html')['data-bs-theme']).to eq('light')
        expect(html.at('body')['data-controller']).to eq('tooltips')
      end
    end
  end
end
