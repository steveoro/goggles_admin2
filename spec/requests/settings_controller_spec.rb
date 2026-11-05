# frozen_string_literal: true

require 'rails_helper'
require 'version'

RSpec.describe SettingsController do
  describe 'GET settings (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(settings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API doubles:
        allow(APIProxy).to receive(:ping)
          .and_return(DummyResponse.new(body: { msg: 'OK', version: Version::FULL }.to_json))
        # Stub/double any possible call:
        (GogglesDb::AppParameter::SETTINGS_GROUPS + [:prefs]).each do |group_key|
          cfg_row = group_key.to_sym == :prefs ? admin_user : GogglesDb::AppParameter.config
          if cfg_row.settings(group_key).value.present?
            cfg_row.settings(group_key).value.each do |key, val|
              allow(APIProxy).to receive(:call).with(
                method: :get, url: "setting/#{group_key}", jwt: admin_user.jwt
              ).and_return(DummyResponse.new(body: Setting.new(group_key:, key:, value: val).to_json))
            end
          else
            allow(APIProxy).to receive(:call).with(
              method: :get, url: "setting/#{group_key}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: {}.to_json))
          end
        end
      end

      it 'returns http success' do
        get(settings_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT setting (update)' do
    let(:fixture_group_key) { :app }
    let(:new_key) { FFaker::Lorem.word }
    let(:new_value) { FFaker::Lorem.sentence }
    let(:fixture_row) { Setting.new(group_key: fixture_group_key, key: new_key, value: new_value) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(setting_path(fixture_row.id), params: { group_key: fixture_group_key, new_key => new_value })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :put, url: "setting/#{fixture_group_key}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(setting_path(fixture_row.id), params: { group_key: fixture_group_key, new_key => new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE settings (destroy)' do
    let(:fixture_group_key) { :app }
    let(:new_key) { FFaker::Lorem.word }
    let(:new_value) { FFaker::Lorem.sentence }
    let(:fixture_row) { Setting.new(group_key: fixture_group_key, key: new_key, value: new_value) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(settings_destroy_path, params: { id: fixture_row.id })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user, when destroying a single row,' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :delete, url: "setting/#{fixture_group_key}", jwt: admin_user.jwt,
            payload: { key: new_key }
          ).and_return(DummyResponse.new(body: 'true'))
        delete(settings_destroy_path(id: fixture_row.id))
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST settings/api_config' do
    let(:new_value) { 'https://dont-care-whats-here.org/' }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(settings_api_config_path, params: { connect_to: new_value })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user and a reachable new API URL' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:ping)
          .and_return(DummyResponse.new(body: { msg: 'OK', version: Version::FULL }.to_json))
        post(settings_api_config_path, params: { connect_to: new_value })
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'saves the new URL (without trailing slash) and probes it' do
        expect(APIProxy.configured_base_url).to eq('https://dont-care-whats-here.org')
        expect(APIProxy).to have_received(:ping).with('https://dont-care-whats-here.org')
        expect(flash[:info]).to include(Version::FULL)
      end

      it 'signs out the user, redirecting to the sign-in page' do
        expect(response).to redirect_to(new_user_session_path)
        get(settings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with an API-offline session and an unreachable new API URL' do
      include AdminSignInHelpers

      before(:each) do
        sign_in_api_offline(prepare_admin_user)
        allow(APIProxy).to receive(:ping).and_return(unreachable_api_result(new_value))
        post(settings_api_config_path, params: { connect_to: new_value })
      end

      it 'saves the new URL anyway, warning about the failed probe' do
        expect(APIProxy.configured_base_url).to eq('https://dont-care-whats-here.org')
        expect(flash[:warning]).to include('API unreachable')
        expect(flash[:error]).to be_nil
      end

      it 'signs out the user & clears the API-offline flag' do
        expect(session[:api_offline]).to be_nil
        get(settings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a blank URL' do
      include AdminSignInHelpers

      before(:each) do
        sign_in_admin(prepare_admin_user)
        post(settings_api_config_path, params: { connect_to: ' ' })
      end

      it 'sets the flash error message and leaves the URL untouched' do
        expect(flash[:error]).to eq(I18n.t('dashboard.generic_param_miss_error'))
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'API-offline sessions' do
    include AdminSignInHelpers

    let(:admin_user) { prepare_admin_user }

    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive(:ping).and_return(unreachable_api_result)
    end

    describe 'GET settings (index)' do
      before(:each) { get(settings_path) }

      it 'renders the local, read-only settings without calling the remote endpoints' do
        expect(response).to have_http_status(:success)
        expect(APIProxy).not_to have_received(:call).with(hash_including(url: 'setting/app'))
        expect(response.body).to include('api-offline-help')
        expect(response.body).not_to include('api-offline-banner') # (the settings page has its own box)
        expect(response.body).to include(GogglesDb::AppParameter.connection_db_config.database)
        expect(response.body).not_to include('REMOTE ')
      end

      it 'shows the unreachable status' do
        expect(response.body).to include('API unreachable')
      end
    end

    describe 'PUT setting (update)' do
      it 'is refused' do
        allow(APIProxy).to receive(:call).with(hash_including(method: :put)).and_return(DummyResponse.new(body: 'true'))
        put(setting_path('app§x'), params: { group_key: 'app', key: 'x', value: 'y' })
        expect(APIProxy).not_to have_received(:call).with(hash_including(method: :put))
        expect(flash[:error]).to eq(I18n.t('api_offline.read_only'))
        expect(response).to redirect_to(settings_path)
      end
    end
  end

  describe 'GET settings (index) with a valid JWT but an API server that just went down' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
      allow(APIProxy).to receive_messages(ping: unreachable_api_result, call: unreachable_api_result)
      get(settings_path)
    end

    it 'falls back to the local settings' do
      expect(response).to have_http_status(:success)
      expect(response.body).to include(GogglesDb::AppParameter.connection_db_config.database)
      expect(response.body).not_to include('api-offline-banner')
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
