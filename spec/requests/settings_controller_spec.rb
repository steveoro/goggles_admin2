# frozen_string_literal: true

require 'rails_helper'
require 'version'

RSpec.describe SettingsController, type: :request do
  describe 'GET /index' do
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
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'status', jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: { msg: 'OK', version: Version::FULL }.to_json))
        # Stub/double any possible call:
        (GogglesDb::AppParameter::SETTINGS_GROUPS + [:prefs]).each do |group_key|
          cfg_row = group_key.to_sym == :prefs ? admin_user : GogglesDb::AppParameter.config
          if cfg_row.settings(group_key).value.present?
            cfg_row.settings(group_key).value.each do |key, val|
              allow(APIProxy).to receive(:call).with(
                method: :get, url: "setting/#{group_key}", jwt: admin_user.jwt
              ).and_return(DummyResponse.new(body: Setting.new(group_key: group_key, key: key, value: val).to_json))
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

  describe 'PUT /update' do
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
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE /destroy' do
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
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST /api_config' do
    let(:new_value) { 'https://dont-care-whats-here.org/' }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(settings_api_config_path, params: { connect_to: new_value })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        post(settings_api_config_path, params: { connect_to: new_value })
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(settings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
