# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIUsersController, type: :request do
  describe 'GET /index' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_users_path)
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
          method: :get, url: 'users', jwt: admin_user.jwt,
          params: { page: anything, per_page: anything }
        ).and_return(DummyResponse.new(body: GogglesDb::User.all.to_json))
      end

      it 'returns http success' do
        get(api_users_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT /update' do
    let(:fixture_row) { FactoryBot.create(:user) }
    let(:new_value) { "#{FFaker::Name.first_name} #{FFaker::Name.last_name}" }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_user_path(fixture_row.id), params: { complete_name: new_value })
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
            method: :put, url: "user/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_user_path(fixture_row.id), params: { complete_name: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_users_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE /destroy' do
    let(:fixture_row) { FactoryBot.create(:user) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_users_destroy_path(id: fixture_row.id))
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user,' do
      include AdminSignInHelpers
      context 'when destroying a single row,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          # API double:
          allow(APIProxy).to receive(:call)
            .with(
              method: :delete, url: "user/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_users_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_users_path)
        end
      end

      context 'when trying to destroy a required ID user (default admins),' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          delete(api_users_destroy_path(id: [1, 2, 3].sample))
        end

        it 'sets the flash no-ops message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.no_op_msg'))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_users_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
