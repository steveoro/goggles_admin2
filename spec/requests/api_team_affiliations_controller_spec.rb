# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APITeamAffiliationsController, type: :request do
  describe 'GET api_team_affiliations (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_team_affiliations_path)
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
          method: :get, url: 'team_affiliations', jwt: admin_user.jwt,
          params: {
            season_id: anything, name: anything,
            compute_gogglecup: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::TeamAffiliation.first(25).to_json))
      end

      it 'returns http success' do
        get(api_team_affiliations_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_team_affiliation (update)' do
    let(:fixture_row) { FactoryBot.create(:team_affiliation) }
    let(:new_value) { GogglesDb::Team.pluck(:id).first(100).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_team_affiliation_path(fixture_row.id), params: { team_id: new_value })
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
            method: :put, url: "team_affiliation/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_team_affiliation_path(fixture_row.id), params: { team_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_team_affiliations_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_team_affiliations (create)' do
    let(:new_attributes) { FactoryBot.build(:team_affiliation).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_team_affiliations_path, params: new_attributes)
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
            method: :post, url: 'team_affiliation', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: -1 } }.to_json))
        post(api_team_affiliations_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_team_affiliations_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_team_affiliations (destroy)' do
    let(:fixture_row) { FactoryBot.create(:team_affiliation) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_team_affiliations_destroy_path(id: fixture_row.id))
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
              method: :delete, url: "team_affiliation/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_team_affiliations_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_team_affiliations_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
