# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GogglesCupPreview' do
  describe 'GET /best_results/goggles_cup_preview' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get goggles_cup_preview_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
      end

      it 'returns http success for phase 1 (team selection)' do
        get goggles_cup_preview_path
        expect(response).to have_http_status(:success)
      end

      context 'with a team selected' do
        let(:team) { create(:team) }
        let(:swimmer) { create(:swimmer) }

        before(:each) do
          # Create some test data in the view
          create(:best_swimmer_current_vs_previous_result, team: team, swimmer: swimimmer)
        end

        it 'returns http success for phase 2 (swimmer selection)' do
          get goggles_cup_preview_path, params: { team_id: team.id }
          expect(response).to have_http_status(:success)
        end

        it 'displays swimmers for the selected team' do
          get goggles_cup_preview_path, params: { team_id: team.id }
          expect(response.body).to include(swimmer.complete_name)
        end

        context 'with swimmers selected for ranking' do
          it 'computes ranking on POST' do
            post goggles_cup_preview_path, params: { team_id: team.id, swimmer_ids: [swimmer.id] }
            expect(response).to have_http_status(:success)
          end
        end
      end
    end
  end
end
