# frozen_string_literal: true

require 'rails_helper'

# Gate implemented by APISession / ApplicationController#check_jwt_session
RSpec.describe 'API-offline sessions' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }

  context 'with an API-offline session (localhost)' do
    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive_messages(call: unreachable_api_result, ping: unreachable_api_result)
    end

    it 'allows the home page, showing the offline banner' do
      get(root_path)
      expect(response).to have_http_status(:success)
      expect(response.body).to include('api-offline-banner')
    end

    it 'redirects any API-dependent page to the settings' do
      get(api_users_path)
      expect(response).to redirect_to(settings_path)
      expect(flash[:warning]).to eq(I18n.t('api_offline.redirected'))
    end

    it 'stops being offline as soon as the user gets a valid JWT' do
      admin_user.reload.update!( # (sign-in bumped its lock_version)
        jwt: GogglesDb::JWTManager.encode({ user_id: admin_user.id }, Rails.application.credentials.api_static_key)
      )
      get(root_path)
      expect(session[:api_offline]).to be_nil
      expect(response.body).not_to include('api-offline-banner')
    end

    it 'is no longer valid when the same session is used from a remote IP' do
      get(root_path, headers: { 'REMOTE_ADDR' => '10.1.2.3' })
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with a regular session whose JWT has expired' do
    before(:each) do
      sign_in_admin(admin_user)
      admin_user.update!(jwt: nil)
      get(root_path)
    end

    it 'still forces a new sign-in' do
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with an anonymous visitor' do
    it 'shows the sign-in page without errors' do
      get(new_user_session_path)
      expect(response).to have_http_status(:success)
      expect(flash[:error]).to be_nil
    end
  end
end
