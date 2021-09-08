# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meetings', type: :request do
  describe 'GET /index' do
    context 'for an unlogged user' do
      it 'is a redirect to the login path' do
        get(meetings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'for a logged-in user' do
      include AdminSignInHelpers
      before(:each) { sign_in_admin(prepare_admin_user) }

      it 'returns http success' do
        get(meetings_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # TODO
end
