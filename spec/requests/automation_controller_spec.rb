# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationController do
  include AdminSignInHelpers

  it 'redirects an unlogged user to the login path' do
    post(automation_switch_path, params: { switch: 'enabled', value: '0' })
    expect(response).to redirect_to(new_user_session_path)
    expect(DataFix::Automation.enabled?).to be true
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

    it 'refuses an unknown switch' do
      post(automation_switch_path, params: { switch: 'commit', value: '1' })
      expect(flash[:error]).to eq(I18n.t('pipeline_automation.flash.unknown_switch', switch: 'commit'))
    end

    it 'warns that ADMIN2_AUTOMATION=0 still forces everything off' do
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      post(automation_switch_path, params: { switch: 'enabled', value: '1' })
      expect(flash[:warning]).to eq(I18n.t('pipeline_automation.flash.env_override'))
    end
  end
end
