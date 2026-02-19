# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'BestResults' do
  describe 'GET /best_results/best_50m' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get best_50m_results_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
      end

      it 'returns http success' do
        get best_50m_results_path
        expect(response).to have_http_status(:success)
      end
    end
  end
end
