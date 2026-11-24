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

      it 'renders the result list of a selected team (no missing translations)' do
        team = FactoryBot.create(:team) # (no swimmers: the empty-list message)
        get best_50m_results_path(team_id: team.id)
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('best_results.list.no_results_found'))
      end

      it 'renders the per-swimmer results of a team with results' do
        result = GogglesDb::BestSwimmerAllTimeResult.first
        skip('no all-time best results in the test DB') unless result

        get all_time_best_results_path(team_id: result.team_id)
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('best_results.list.best_timing'))
      end
    end
  end
end
