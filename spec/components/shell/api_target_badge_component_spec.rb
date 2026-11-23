# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::APITargetBadgeComponent, type: :component do
  subject(:html) { render_inline(described_class.new(api_target: Shell::APITarget.new(url: api_url))) }

  let(:api_url) { 'http://localhost:8081' }

  after(:each) { Ops::Database.reset_state! }

  it 'links to the Settings page showing the URL' do
    badge = html.at_css('a#api-target-badge')
    expect(badge['href']).to eq('/settings')
    expect(badge.text).to include('localhost:8081')
  end

  it 'marks an unknown target as "unknown (unverified)" with the secondary accent' do
    guess = html.at_css('.app-env-badge')
    expect(guess['class']).to include('app-env-badge--unknown')
    expect(guess.text.squish).to start_with("#{I18n.t('shell.api_target.guess.unknown')} (#{I18n.t('shell.api_target.unverified')})")
    expect(html.at_css('#api-target-badge')['data-bs-title']).to include(I18n.t('shell.api_target.unverified'))
  end

  context 'with a URL on port 447' do
    let(:api_url) { 'https://master-goggles.org:447' }

    it 'guesses "production (unverified)" with the red accent, never "staging"' do
      guess = html.at_css('.app-env-badge')
      expect(guess['class']).to include('app-env-badge--production')
      expect(guess.text).to include(I18n.t('shell.api_target.guess.production'), I18n.t('shell.api_target.unverified'))
      expect(html.to_html).not_to match(/staging/i)
    end
  end

  context 'with an API that reports its environment (phase 08)' do
    def store_status(environment)
      body = { msg: 'OK', version: '7.3', environment:, capabilities: [] }
      SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
    end

    it 'shows the reported environment, without "unverified"' do
      store_status('development')
      badge = html.at_css('#api-target-badge')
      expect(badge['data-api-verified']).to eq('true')
      expect(badge['data-api-environment']).to eq('development')
      expect(html.at_css('.app-env-badge').text.squish).to eq('development')
      expect(badge['data-bs-title']).to include(I18n.t('shell.api_target.reported', environment: 'development'))
      expect(badge['data-bs-title']).not_to include(I18n.t('shell.api_target.unverified'))
    end

    it 'warns when the operator label names another environment' do
      store_status('development')
      Shell::APITarget.store_label!(api_url, 'Production')
      expect(html.at_css('.app-api-mismatch')).to be_present
      expect(html.at_css('#api-target-badge')['data-bs-title'])
        .to include(I18n.t('shell.api_target.label_mismatch', label: 'Production', environment: 'development'))
    end

    it 'uses the production accent for a production API, whatever the port' do
      store_status('production')
      expect(html.at_css('.app-env-badge')['class']).to include('app-env-badge--production')
      expect(html.at_css('.app-api-mismatch')).to be_nil
    end
  end

  it 'shows the operator label when set' do
    Shell::APITarget.store_label!(api_url, 'Local copy')
    expect(html.at_css('.app-api-label').text).to eq('Local copy')
  end

  it 'shows the reachability and age from the ping snapshot' do
    Ops::Snapshot.write!("api.status:#{api_url}", { 'reachable' => true, 'code' => 200, 'version' => '7.2' })
    badge = html.at_css('#api-target-badge')
    expect(badge['data-api-reachability']).to eq('reachable')
    expect(badge.text).to include(I18n.t('shell.api_target.reachability.reachable'))
    expect(badge['data-bs-title']).to include('7.2')
  end

  it 'shows an unknown reachability without a snapshot' do
    expect(html.at_css('#api-target-badge')['data-api-reachability']).to eq('unknown')
  end
end
