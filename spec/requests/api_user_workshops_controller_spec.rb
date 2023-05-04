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
      before(:each) { sign_in_admin(prepare_admin_user) }

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
