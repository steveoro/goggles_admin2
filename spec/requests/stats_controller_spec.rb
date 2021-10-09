# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Stats', type: :request do
  describe 'GET stats (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(stats_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'api_daily_uses', jwt: admin_user.jwt,
          params: {
            route: anything, day: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::APIDailyUse.first(50).to_json))
      end

      it 'returns http success' do
        get(stats_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT stats (update)' do
    let(:fixture_row) { FactoryBot.create(:api_daily_use) }
    let(:new_value) { "REQ-#{FFaker::Lorem.word}/#{FFaker::Lorem.word}" }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(stat_path(fixture_row.id), params: { route: new_value })
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
            method: :put, url: "api_daily_use/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(stat_path(fixture_row.id), params: { route: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(stats_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE stats (destroy)' do
    let(:fixture_row) { FactoryBot.create(:api_daily_use) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(stats_destroy_path(id: fixture_row.id))
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
            method: :delete, url: "api_daily_use/#{fixture_row.id}", jwt: admin_user.jwt
          ).and_return(DummyResponse.new(body: 'true'))
        delete(stats_destroy_path(id: fixture_row.id))
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(stats_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
