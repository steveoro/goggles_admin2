# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIMeetingsController do
  describe 'GET api_meetings (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_meetings_path)
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
          method: :get, url: 'meetings', jwt: admin_user.jwt,
          params: {
            name: anything, description: anything,
            header_date: anything, header_year: anything,
            season_id: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::Meeting.first(25).to_json))
        get(api_meetings_path)
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_meeting (update)' do
    let(:fixture_row) { FactoryBot.create(:meeting) }
    let(:new_value) { GogglesDb::Season.pluck(:id).first(100).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_meeting_path(fixture_row.id), params: { season_id: new_value })
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
            method: :put, url: "meeting/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_meeting_path(fixture_row.id), params: { season_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_meetings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_meetings/clone' do
    let(:clone_source_id) { GogglesDb::Meeting.pluck(:id).last(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_meetings_clone_path, params: { id: clone_source_id })
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
            method: :post, url: "meeting/clone/#{clone_source_id}", jwt: admin_user.jwt
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(api_meetings_clone_path, params: { id: clone_source_id })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_meetings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
