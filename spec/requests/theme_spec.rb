# frozen_string_literal: true

require 'rails_helper'
require 'version'

# The 'theme' cookie drives the layout's <html data-bs-theme> and the navbar toggle.
RSpec.describe 'Light/dark theme' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:html) { response.parsed_body }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive_messages(
      call: DummyResponse.new(body: {}.to_json),
      ping: DummyResponse.new(body: { msg: 'OK', version: Version::FULL }.to_json)
    )
  end

  it "renders data-bs-theme='light' without a cookie" do
    get(root_path)
    expect(html.at('html')['data-bs-theme']).to eq('light')
  end

  it "renders data-bs-theme='dark' with the dark cookie" do
    cookies[:theme] = 'dark'
    get(root_path)
    expect(html.at('html')['data-bs-theme']).to eq('dark')
  end

  it "falls back to 'light' for an unsupported cookie value" do
    cookies[:theme] = 'neon'
    get(root_path)
    expect(html.at('html')['data-bs-theme']).to eq('light')
  end

  it 'renders the toggle button wired to the theme controller' do
    get(root_path)
    button = html.at_css('#theme-toggle')
    expect(button['data-action']).to eq('theme#toggle')
    expect(button['aria-pressed']).to eq('false')
    expect(button.ancestors('[data-controller~="theme"]')).not_to be_empty
  end
end
