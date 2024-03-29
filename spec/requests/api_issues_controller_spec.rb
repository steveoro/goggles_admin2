# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIIssuesController do
  describe 'GET api_issues (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_issues_path)
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
          method: :get, url: 'issues', jwt: admin_user.jwt,
          params: { page: anything, per_page: anything }
        ).and_return(DummyResponse.new(body: GogglesDb::Issue.all.to_json))
      end

      it 'returns http success' do
        get(api_issues_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_issue (update)' do
    let(:fixture_row) { FactoryBot.create(:issue) }
    let(:new_request_data) do
      {
        target_entity: 'Swimmer',
        swimmer: { id: -1, complete_name: '(Never mind: this will not get processed)' }
      }.to_json
    end

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_issue_path(fixture_row.id), params: { request_data: new_request_data })
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
            method: :put, url: "issue/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_issue_path(fixture_row.id), params: { request_data: new_request_data })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_issues_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_issues (create)' do
    let(:new_attributes) { FactoryBot.build(:issue).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_issues_path, params: new_attributes)
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
            method: :post, url: 'issue', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: -1 } }.to_json))
        post(api_issues_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
        # (Can't really say which ID will be randomly generated by the WebMock)
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_issues_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_issues (destroy)' do
    let(:fixture_row) { FactoryBot.create(:issue) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_issues_destroy_path(id: fixture_row.id))
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
              method: :delete, url: "issue/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_issues_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_issues_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
