# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Operations switch (POST /operations/switch)' do
  include AdminSignInHelpers

  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }

  def streams = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')

  def stream(target) = streams.find { |node| node['target'] == target }

  around(:each) { |example| I18n.with_locale(:en) { example.run } }

  it 'redirects an unlogged user to the login path, storing nothing' do
    post(operations_switch_path, params: { value: '0', return_to: 'dashboard' })
    expect(response).to redirect_to(new_user_session_path)
    expect(Maintenance.enabled?).to be true
  end

  it 'works in an API-offline session, while the /operations page stays API-only (api_offline_allowed?)' do
    sign_in_api_offline(prepare_admin_user)
    allow(APIProxy).to receive_messages(call: unreachable_api_result, ping: unreachable_api_result)
    post(operations_switch_path, params: { value: '0', return_to: 'dashboard' })
    expect(response).to redirect_to("#{root_path}#dashboard-system")
    expect(Maintenance.enabled?).to be false
    get(operations_path)
    expect(response).to redirect_to(settings_path)
  end

  context 'with a logged-in user' do
    before(:each) do
      sign_in_admin(prepare_admin_user)
      allow(APIProxy).to receive(:call).and_raise('no API call expected')
    end

    it 'turns the operations off and on from the dashboard (turbo stream: the switch and the toasts), recording events' do # rubocop:disable RSpec/MultipleExpectations
      post(operations_switch_path, params: { value: '0', return_to: 'dashboard' }, headers: turbo_headers)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(Maintenance.enabled?).to be false
      expect(streams.to_h { |node| [node['target'], node['action']] })
        .to eq('operations-switch-dashboard' => 'replace', 'flash-messages-container' => 'update')
      panel = Nokogiri::HTML5.fragment(stream('operations-switch-dashboard').at_css('template').inner_html)
      expect(panel.at_css('#operations-switch-dashboard')['data-operations-enabled']).to eq('false')
      expect(panel.at_css('#operations-switch-input-dashboard')['checked']).to be_nil
      expect(stream('flash-messages-container').text).to include(I18n.t('maintenance.switch.flash.off'))
      event = Ops::Event.order(:id).last
      expect(event).to have_attributes(kind: 'operations.switched', level: 'warning', subject_key: Maintenance::ENABLED_SETTING)
      expect(event.data).to include('value' => false)
      expect(event.title).to eq(I18n.t('ops.events.operations.switched'))

      post(operations_switch_path, params: { value: '1', return_to: 'dashboard' }, headers: turbo_headers)
      expect(Maintenance.enabled?).to be true
      expect(stream('flash-messages-container').text).to include(I18n.t('maintenance.switch.flash.on'))
    end

    it 'redirects back to /operations from its header (the whole page depends on the setting), Turbo or not' do
      post(operations_switch_path, params: { value: '0', return_to: 'operations' }, headers: turbo_headers)
      expect(response).to redirect_to(operations_path)
      expect(flash[:info]).to eq(I18n.t('maintenance.switch.flash.off'))
      follow_redirect!
      body = response.parsed_body
      expect(body.at_css('#operations-disabled')).to be_present
      # (still shown when off, so that the operations can be turned back on)
      expect(body.at_css('.app-page-actions #operations-switch-operations input[role=switch]')['checked']).to be_nil

      post(operations_switch_path, params: { value: '1', return_to: 'operations' })
      expect(response).to redirect_to(operations_path)
      follow_redirect!
      expect(response.parsed_body.at_css('#operations-disabled')).to be_nil
      expect(response.parsed_body.at_css('#operations-switch-operations input[role=switch]')['checked']).to be_present
    end

    it 'redirects a plain request from the dashboard back to its system column' do
      post(operations_switch_path, params: { value: '0', return_to: 'dashboard' })
      expect(response).to redirect_to("#{root_path}#dashboard-system")
      expect(Maintenance.enabled?).to be false
    end

    it 'refuses without the ops DB, and renders the switch disabled with the reason' do
      allow(Ops).to receive(:available?).and_return(false)
      post(operations_switch_path, params: { value: '0', return_to: 'dashboard' }, headers: turbo_headers)
      expect(stream('flash-messages-container').text).to include(I18n.t('maintenance.switch.flash.ops_unavailable'))
      panel = Nokogiri::HTML5.fragment(stream('operations-switch-dashboard').at_css('template').inner_html)
      expect(panel.at_css('#operations-switch-input-dashboard')['disabled']).to be_present
      expect(panel.at_css('.form-switch')['title']).to eq(I18n.t('maintenance.switch.ops_unavailable'))
      # (the reason is also shown as text, and described to assistive technologies)
      expect(panel.at_css('#operations-switch-input-dashboard-description:not(.visually-hidden)').text).to eq(I18n.t('maintenance.switch.ops_unavailable'))
    end

    def panel = Nokogiri::HTML5.fragment(stream('operations-switch-dashboard').at_css('template').inner_html)

    it 'says so when the setting cannot be stored, and shows the old stored position' do
      allow(Maintenance).to receive(:store_enabled!).and_return(nil)
      post(operations_switch_path, params: { value: '0', return_to: 'dashboard' }, headers: turbo_headers)
      expect(stream('flash-messages-container').text).to include(I18n.t('maintenance.switch.flash.store_failed'))
      expect(panel.at_css('#operations-switch-input-dashboard')['checked']).to be_present
      expect(Maintenance.enabled?).to be true
    end

    it 'keeps the old position and records nothing when the ops setting write raises' do
      Ops::Setting.store!(Maintenance::ENABLED_SETTING, false)
      allow(Ops::Setting).to receive(:store!).and_raise(ActiveRecord::StatementInvalid, 'locked')
      post(operations_switch_path, params: { value: '1', return_to: 'dashboard' }, headers: turbo_headers)
      expect(panel.at_css('#operations-switch-input-dashboard')['checked']).to be_nil
      expect(panel.at_css('[data-operations-state]')['data-operations-state']).to eq('off')
      expect(Maintenance.enabled?).to be false
      expect(Ops::Event.where(kind: Maintenance::SWITCH_EVENT_KIND)).to be_empty
    end

    it 'shows an unreadable setting disabled with its reason (never an interactive guess)' do
      allow(Ops::Setting).to receive(:fetch).and_call_original
      allow(Ops::Setting).to receive(:fetch).with(Maintenance::ENABLED_SETTING, true).and_raise(ActiveRecord::StatementInvalid, 'locked')
      get(dashboard_system_path)
      switch = response.parsed_body.at_css('#operations-switch-input-dashboard')
      expect(switch.to_h.slice('checked', 'disabled', 'aria-describedby'))
        .to eq('disabled' => 'disabled', 'aria-describedby' => 'operations-switch-input-dashboard-description')
      expect(response.parsed_body.at_css('#operations-switch-input-dashboard-description').text).to eq(I18n.t('maintenance.switch.unreadable'))
      expect(response.parsed_body.at_css('#operations-switch-dashboard [data-operations-state]').text).to eq(I18n.t('maintenance.switch.states.unknown'))
    end

    it 'reads a missing or garbage value as off' do
      post(operations_switch_path, params: { return_to: 'dashboard' })
      expect(Maintenance.enabled?).to be false
      Maintenance.store_enabled!(true)
      post(operations_switch_path, params: { value: 'on', return_to: 'dashboard' })
      expect(Maintenance.enabled?).to be false
    end
  end
end
