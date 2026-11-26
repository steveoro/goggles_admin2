# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationController do
  include AdminSignInHelpers

  it 'redirects an unlogged user to the login path' do
    post(automation_switch_path, params: { switch: 'enabled', value: '0' })
    expect(response).to redirect_to(new_user_session_path)
    expect(DataFix::Automation.enabled?).to be true
  end

  it 'works in an API-offline session (local ops DB only: api_offline_allowed?)' do
    sign_in_api_offline(prepare_admin_user)
    allow(APIProxy).to receive_messages(call: unreachable_api_result, ping: unreachable_api_result)
    post(automation_switch_path, params: { switch: 'auto_extract', value: '0' })
    expect(response).to redirect_to("#{root_path}#dashboard-system")
    expect(DataFix::Automation.enabled?(:auto_extract)).to be false
  end

  context 'with a logged-in user' do
    around(:each) { |example| I18n.with_locale(:en) { example.run } }

    before(:each) { sign_in_admin(prepare_admin_user) }

    it 'turns a switch off and on again, back to the dashboard system column' do
      post(automation_switch_path, params: { switch: 'auto_extract', value: '0' })
      expect(response).to redirect_to("#{root_path}#dashboard-system")
      expect(DataFix::Automation.enabled?(:auto_extract)).to be false
      expect(Ops::Event.order(:id).last.kind).to eq('automation.switched')

      post(automation_switch_path, params: { switch: 'auto_extract', value: '1', return_to: 'season_board' })
      expect(response).to redirect_to(season_board_path)
      expect(DataFix::Automation.enabled?(:auto_extract)).to be true
    end

    it 'redirects a request accepting anything (no Turbo)' do
      post(automation_switch_path, params: { switch: 'auto_extract', value: '0' }, headers: { 'Accept' => '*/*' })
      expect(response).to redirect_to("#{root_path}#dashboard-system")
    end

    it 'reads a missing or garbage value as off' do
      post(automation_switch_path, params: { switch: 'auto_extract' })
      expect(DataFix::Automation.stored(:auto_extract)).to be false
      DataFix::Automation.store!(:auto_extract, true)
      post(automation_switch_path, params: { switch: 'auto_extract', value: 'yes please' })
      expect(DataFix::Automation.stored(:auto_extract)).to be false
    end

    it 'refuses an unknown switch' do
      post(automation_switch_path, params: { switch: 'commit', value: '1' })
      expect(flash[:error]).to eq(I18n.t('pipeline_automation.flash.unknown_switch', switch: 'commit'))
    end

    it 'warns that ADMIN2_AUTOMATION=0 still forces everything off' do
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      post(automation_switch_path, params: { switch: 'enabled', value: '1' })
      expect(flash[:warning]).to eq(I18n.t('pipeline_automation.flash.env_override'))
    end

    describe 'the FIN change alert hidden while the automation waits (0.10.103)' do
      let(:store) { FedernuotoWatch::StateStore.new }
      let(:change) { { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k', 'name' => 'Waiting meeting', 'url' => '' }] } }

      before(:each) do
        store.update { { 'digest' => 'd1', 'rows' => [], 'change' => change } }
        FedernuotoWatch::Progress.store!('digest' => 'd1', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
      end

      after(:each) { FileUtils.rm_f(store.path) }

      it 'shows in every tab as soon as the master switch is turned off, without waiting for any job' do
        expect { post(automation_switch_path, params: { switch: 'enabled', value: '0' }) }
          .to have_broadcasted_to(AppNotificationsChannel::STREAM).with(a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID,
                                                                                         html: a_string_including('Waiting meeting')))
        expect(FedernuotoWatch::Progress.read('d1')).to be_nil
        get(sources_crawler_path)
        expect(response.parsed_body.at_css("##{FedernuotoWatch::ALERT_DOM_ID}")).to be_present
      end

      it 'shows again when the calendar switch is toggled, not for the other switches' do
        expect { post(automation_switch_path, params: { switch: 'auto_extract', value: '0' }) }
          .not_to have_broadcasted_to(AppNotificationsChannel::STREAM).with(a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID))
        expect { post(automation_switch_path, params: { switch: 'auto_calendar', value: '0' }) }
          .to have_broadcasted_to(AppNotificationsChannel::STREAM).with(a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID))
      end
    end

    describe 'a Turbo request (the switches, Switch::ToggleFormComponent)' do
      let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }

      def streams = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')

      def stream(target) = streams.find { |node| node['target'] == target }

      def template(target) = Nokogiri::HTML5.fragment(stream(target).at_css('template').inner_html)

      it 'answers with a turbo stream replacing both panels, the board badge and button, and the toasts' do # rubocop:disable RSpec/MultipleExpectations
        post(automation_switch_path, params: { switch: 'auto_prepare', value: '0', return_to: 'season_board' }, headers: turbo_headers)
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        expect(DataFix::Automation.enabled?(:auto_prepare)).to be false
        expect(streams.to_h { |node| [node['target'], node['action']] }).to eq(
          'automation-switches-dashboard' => 'replace', 'automation-switches-season_board' => 'replace',
          'season-board-automation-badge' => 'replace', 'season-board-prepare-all' => 'replace',
          'flash-messages-container' => 'update'
        )
        panel = template('automation-switches-season_board')
        expect(panel.at_css('[data-automation-switch="auto_prepare"]')['data-automation-state']).to eq('off')
        expect(panel.at_css('#automation-switch-season_board-auto_prepare')['checked']).to be_nil
        expect(panel.at_css('#automation-switch-season_board-enabled')['checked']).to be_present
        expect(template('automation-switches-dashboard').at_css('#automation-switch-dashboard-auto_prepare')).to be_present
        expect(template('season-board-automation-badge').at_css('#season-board-automation-badge')['data-automation-paused']).to eq('true')
        expect(template('season-board-prepare-all').at_css('#btn-season-board-prepare-all')['disabled']).to be_present
        expect(stream('flash-messages-container').text)
          .to include(I18n.t('pipeline_automation.flash.switch_off', switch: I18n.t('pipeline_automation.switches.auto_prepare.label')))
        # (the toast is shown by this response only)
        get(dashboard_system_path)
        expect(flash[:info]).to be_nil
      end

      it 'answers an unknown switch with the error toast, storing nothing' do
        post(automation_switch_path, params: { switch: 'commit', value: '1' }, headers: turbo_headers)
        expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.unknown_switch', switch: 'commit'))
        expect(Ops::Event.where(kind: DataFix::Automation::EVENT_KIND)).to be_empty
      end

      it 'shows the old stored position, with an error toast and no event, when the store fails' do
        allow(DataFix::Automation).to receive(:store!).and_return(nil)
        post(automation_switch_path, params: { switch: 'auto_prepare', value: '0' }, headers: turbo_headers)
        expect(template('automation-switches-dashboard').at_css('#automation-switch-dashboard-auto_prepare')['checked']).to be_present
        expect(stream('flash-messages-container').text)
          .to include(I18n.t('pipeline_automation.flash.store_failed', switch: I18n.t('pipeline_automation.switches.auto_prepare.label')))
      end

      it 'records nothing and keeps the position when the ops setting write raises' do
        allow(Ops::Setting).to receive(:store!).and_raise(ActiveRecord::StatementInvalid, 'locked')
        post(automation_switch_path, params: { switch: 'auto_prepare', value: '0' }, headers: turbo_headers)
        expect(template('automation-switches-season_board').at_css('#automation-switch-season_board-auto_prepare')['checked']).to be_present
        expect(DataFix::Automation.enabled?(:auto_prepare)).to be true
        expect(Ops::Event.where(kind: DataFix::Automation::EVENT_KIND)).to be_empty
        expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.store_failed',
                                                                          switch: I18n.t('pipeline_automation.switches.auto_prepare.label')))
      end

      it 'shows an unreadable switch as off (fail closed)' do
        allow(Ops::Setting).to receive(:fetch).and_call_original
        allow(Ops::Setting).to receive(:fetch).with('automation.auto_extract', true).and_raise(ActiveRecord::StatementInvalid, 'locked')
        post(automation_switch_path, params: { switch: 'enabled', value: '1' }, headers: turbo_headers)
        panel = template('automation-switches-dashboard')
        expect(panel.at_css('[data-automation-switch="auto_extract"]')['data-automation-state']).to eq('off')
        expect(panel.at_css('#automation-switch-dashboard-auto_extract')['checked']).to be_nil
        expect(panel.at_css('#automation-switch-dashboard-auto_extract')['disabled']).to be_nil
      end

      it 'shows every switch off and disabled, with the reason, while ADMIN2_AUTOMATION=0 forces them off' do
        allow(DataFix::Automation).to receive(:env_off?).and_return(true)
        post(automation_switch_path, params: { switch: 'enabled', value: '1' }, headers: turbo_headers)
        panel = template('automation-switches-dashboard')
        expect(panel.at_css('[data-automation-env-off="true"]')).to be_present
        switches = panel.css('input[role=switch]')
        expect(switches.size).to eq(DataFix::Automation::SWITCHES.size)
        expect(switches.map { |input| [input['checked'], input['disabled'].present?] }).to all(eq([nil, true]))
        reason = I18n.t('pipeline_automation.switches.env_off', key: DataFix::Automation::ENV_KEY)
        expect(panel.css('.form-switch').pluck('title')).to all(eq(reason))
        expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.env_override'))
      end

      it 'shows the switches disabled and refuses the toggle without the ops DB' do
        allow(Ops).to receive(:available?).and_return(false)
        post(automation_switch_path, params: { switch: 'auto_extract', value: '0' }, headers: turbo_headers)
        expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.ops_unavailable'))
        expect(template('automation-switches-dashboard').css('input[role=switch]').map { |input| input['disabled'].present? }).to all(be(true))
      end
    end
  end
end
