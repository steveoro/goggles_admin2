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

      it 'returns http success for the team/rules selection page' do
        get goggles_cup_preview_path
        expect(response).to have_http_status(:success)
      end

      it 'renders the swimmer list when a team is selected' do
        team = FactoryBot.create(:team)
        query = instance_double(GogglesCup::SwimmerOptionsQuery, call: [swimmer_option])
        allow(GogglesCup::SwimmerOptionsQuery).to receive(:new).with(team_id: team.id.to_s).and_return(query)

        get goggles_cup_preview_path, params: { team_id: team.id }

        expect(response).to have_http_status(:success)
        expect(response.body).to include('TEST SWIMMER')
      end
    end
  end

  describe 'GET /best_results/goggles_cup_preview/smart_selection' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'returns smart-selected swimmer ids as JSON' do
      team = FactoryBot.create(:team)
      query = instance_double(GogglesCup::SwimmerOptionsQuery, smart_selected_ids_for: [10, 20])
      allow(GogglesCup::SwimmerOptionsQuery).to receive(:new).with(team_id: team.id.to_s).and_return(query)

      get smart_selection_goggles_cup_preview_path, params: { team_id: team.id, secondary_team_id: 99 }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq('swimmer_ids' => [10, 20])
    end
  end

  describe 'POST /best_results/goggles_cup_preview/compute' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'returns rendered ranking HTML as JSON' do
      team = FactoryBot.create(:team)
      allow(GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesCup::RankingCalculator, call: [ranking_row]))

      post compute_goggles_cup_preview_path(format: :json), params: { team_id: team.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['html']).to include('TEST SWIMMER')
    end
  end

  def swimmer_option
    { swimmer_id: 1, swimmer_name: 'TEST SWIMMER', swimmer_year_of_birth: 1980 }
  end

  def ranking_row
    {
      swimmer_id: 1,
      swimmer_name: 'TEST SWIMMER',
      swimmer_year_of_birth: 1980,
      overall_score: 1000,
      top_rows: []
    }
  end
end
