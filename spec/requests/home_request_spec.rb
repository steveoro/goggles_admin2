# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Homes', type: :request do
  describe 'GET /index' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(home_index_path)
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
          method: :get, url: anything, jwt: admin_user.jwt
        ).and_return(DummyResponse.new(body: (1..(rand * 200).to_i).to_a))
      end

      it 'returns http success' do
        get(home_index_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
