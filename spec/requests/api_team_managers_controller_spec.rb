# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APITeamManagersController do
  describe 'GET api_team_managers (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_team_managers_path)
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
          method: :get, url: 'team_managers', jwt: admin_user.jwt,
          params: {
            team_affiliation_id: anything, manager_name: anything,
            team_name: anything, season_id: anything,
            season_description: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::ManagedAffiliation.all.to_json))
      end

      it 'returns http success' do
        get(api_team_managers_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_team_manager (update)' do
    let(:fixture_row) { FactoryBot.create(:managed_affiliation) }
    let(:new_value) { GogglesDb::TeamAffiliation.pluck(:id).first(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_team_manager_path(fixture_row.id), params: { team_affiliation_id: new_value })
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
            method: :put, url: "team_manager/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_team_manager_path(fixture_row.id), params: { team_affiliation_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_team_managers_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_team_managers (create)' do
    let(:new_attributes) { FactoryBot.build(:managed_affiliation).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_team_managers_path, params: new_attributes)
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
            method: :post, url: 'team_manager', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(api_team_managers_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_team_managers_path)
      end
    end
  end

  describe 'POST api_team_managers/sql_create (sql_create)' do
    let(:season) { FactoryBot.create(:season) }
    let(:team) { FactoryBot.create(:team) }
    let(:user) { FactoryBot.create(:user) }
    let(:valid_params) { { 'sql-create' => { season_id: season.id, team_id: team.id, user_id: user.id } } }

    after(:each) do
      Rails.root.glob("crawler/data/results.new/#{season.id}/*-team_manager-*.sql").each { |f| File.delete(f) }
    end

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_team_managers_sql_create_path, params: valid_params)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) { sign_in_admin(prepare_admin_user) }

      context 'when all 3 entities are valid and no previous rows exist,' do
        it 'creates the team_affiliations & managed_affiliations rows locally' do
          expect { post(api_team_managers_sql_create_path, params: valid_params) }
            .to change(GogglesDb::TeamAffiliation, :count).by(1)
            .and change(GogglesDb::ManagedAffiliation, :count).by(1)
        end

        it 'writes a SQL batch file under results.new/<season_id>' do
          post(api_team_managers_sql_create_path, params: valid_params)
          files = Rails.root.glob("crawler/data/results.new/#{season.id}/*-team_manager-*.sql")
          expect(files.count).to eq(1)
          sql_content = File.read(files.first)
          expect(sql_content).to include('START TRANSACTION')
            .and include('INSERT INTO `team_affiliations`')
            .and include('INSERT INTO `managed_affiliations`')
            .and include('COMMIT')
        end

        it 'sets the flash success message' do
          post(api_team_managers_sql_create_path, params: valid_params)
          expect(flash[:info]).to be_present
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          post(api_team_managers_sql_create_path, params: valid_params)
          expect(response).to redirect_to(api_team_managers_path)
        end
      end

      context 'when the affiliation exists but the user is not yet linked,' do
        before(:each) { FactoryBot.create(:team_affiliation, team: team, season: season) }

        it 'creates only the managed_affiliations row' do
          expect { post(api_team_managers_sql_create_path, params: valid_params) }
            .to not_change { GogglesDb::TeamAffiliation.count }
            .and change(GogglesDb::ManagedAffiliation, :count).by(1)
        end
      end

      context 'when the managed_affiliations row already exists,' do
        before(:each) do
          affiliation = FactoryBot.create(:team_affiliation, team: team, season: season)
          FactoryBot.create(:managed_affiliation, team_affiliation: affiliation, manager: user)
        end

        it 'sets the flash error message and creates nothing' do
          expect { post(api_team_managers_sql_create_path, params: valid_params) }
            .not_to(change(GogglesDb::ManagedAffiliation, :count))
          expect(flash[:error]).to be_present
          expect(response).to redirect_to(api_team_managers_path)
        end
      end

      context 'with a missing or invalid entity ID,' do
        it 'sets the flash error message and creates nothing' do
          bad_params = { 'sql-create' => { season_id: season.id, team_id: 0, user_id: user.id } }
          expect { post(api_team_managers_sql_create_path, params: bad_params) }
            .not_to(change(GogglesDb::ManagedAffiliation, :count))
          expect(flash[:error]).to be_present
        end
      end

      context 'with missing params,' do
        it 'sets the flash error message and creates nothing' do
          expect { post(api_team_managers_sql_create_path) }
            .not_to(change(GogglesDb::ManagedAffiliation, :count))
          expect(flash[:error]).to be_present
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_team_managers (destroy)' do
    let(:fixture_row) { FactoryBot.create(:managed_affiliation) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_team_managers_destroy_path(id: fixture_row.id))
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
              method: :delete, url: "team_manager/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_team_managers_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_team_managers_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
