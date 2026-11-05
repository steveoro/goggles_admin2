# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Users::SessionsController do
  include AdminSignInHelpers

  let(:password) { 'Password123!' } # (FactoryBot default)
  let(:admin_user) { prepare_admin_user }
  let(:login_params) { { user: { email: admin_user.email, password: } } }
  let(:fresh_jwt) do
    GogglesDb::JWTManager.encode({ user_id: admin_user.id }, Rails.application.credentials.api_static_key)
  end

  describe 'POST /users/sign_in' do
    context 'with an admin user having a still valid JWT' do
      before(:each) do
        allow(APIProxy).to receive(:call)
        post(user_session_path, params: login_params)
      end

      it 'signs-in without calling the API and redirects to the root path' do
        expect(APIProxy).not_to have_received(:call)
        expect(response).to redirect_to(root_path)
        expect(session[:api_offline]).to be_nil
      end
    end

    context 'with an admin user having an expired JWT and a working API' do
      before(:each) do
        admin_user.update!(jwt: nil)
        allow(APIProxy).to receive(:call)
          .with(hash_including(method: :post, url: 'session'))
          .and_return(DummyResponse.new(body: { msg: 'OK', jwt: fresh_jwt }.to_json))
        post(user_session_path, params: login_params)
      end

      it 'stores the new JWT and redirects to the root path' do
        expect(admin_user.reload.jwt).to eq(fresh_jwt)
        expect(response).to redirect_to(root_path)
        expect(session[:api_offline]).to be_nil
      end
    end

    context 'with an admin user having an expired JWT and an unreachable API,' do
      context 'when signing-in from localhost' do
        before(:each) { sign_in_api_offline(admin_user) }

        it 'signs-in as an API-offline session and redirects to the settings' do
          expect(response).to redirect_to(settings_path)
          expect(session[:api_offline]).to include('url' => APIProxy.configured_base_url)
          expect(session[:api_offline]['reason']).to include('API unreachable')
          expect(flash[:warning]).to include(APIProxy.configured_base_url)
        end

        it 'allows to reach the settings page' do
          allow(APIProxy).to receive(:ping).and_return(unreachable_api_result)
          get(settings_path)
          expect(response).to have_http_status(:success)
        end
      end

      context 'when signing-in from a remote IP' do
        before(:each) { sign_in_api_offline(admin_user, headers: { 'REMOTE_ADDR' => '10.1.2.3' }) }

        it 'refuses the sign-in' do
          expect(response).to redirect_to(new_user_session_path)
          expect(flash[:error]).to include('API unreachable')
          expect(session[:api_offline]).to be_nil
          get(root_path, headers: { 'REMOTE_ADDR' => '10.1.2.3' })
          expect(response).to redirect_to(new_user_session_path)
        end
      end
    end

    context 'with a non-admin user' do
      let(:plain_user) { FactoryBot.create(:user) }

      before(:each) do
        allow(APIProxy).to receive(:call)
        post(user_session_path, params: { user: { email: plain_user.email, password: } })
      end

      it 'refuses the sign-in without calling the API' do
        expect(APIProxy).not_to have_received(:call)
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:error]).to eq(I18n.t('devise.api_login.errors.not_an_admin'))
        get(root_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
