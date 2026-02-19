# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIUserWorkshopsController do
  describe 'GET api_user_workshops (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_user_workshops_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'user_workshops', jwt: admin_user.jwt,
          params: {
            name: anything, date: anything,
            header_year: anything, season_id: anything,
            team_id: anything, user_id: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::UserWorkshop.first(25).to_json))
      end

      it 'returns http success' do
        get(api_user_workshops_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # TODO
end
