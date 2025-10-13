# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIBadgesController do
  describe 'GET api_badges (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_badges_path)
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
          method: :get, url: 'badges', jwt: admin_user.jwt,
          params: {
            swimmer_id: anything, team_id: anything,
            season_id: anything,
            fees_due: anything,
            badge_due: anything,
            relays_due: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::Badge.first(25).to_json))
        get(api_badges_path)
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_badge (update)' do
    let(:fixture_row) { FactoryBot.create(:badge) }
    let(:new_value) { GogglesDb::Swimmer.pluck(:id).first(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_badge_path(fixture_row.id), params: { swimmer_id: new_value })
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
            method: :put, url: "badge/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_badge_path(fixture_row.id), params: { swimmer_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_badges_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_badges (create)' do
    let(:new_attributes) { FactoryBot.build(:badge).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_badges_path, params: new_attributes)
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
            method: :post, url: 'badge', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(api_badges_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_badges_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_badges (destroy)' do
    let(:fixture_row) { FactoryBot.create(:badge) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_badges_destroy_path(id: fixture_row.id))
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      context 'when destroying a single row,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          # API double:
          allow(APIProxy).to receive(:call)
            .with(
              method: :delete, url: "badge/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_badges_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_badges_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
