# frozen_string_literal: true

require 'ostruct'
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

  describe 'GET /best_results/goggles_cup_preview/compute (PDF)' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'returns a PDF attachment with ranking details' do
      team = FactoryBot.create(:team)
      allow(GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesCup::RankingCalculator, call: [ranking_row_with_top_rows]))

      get compute_goggles_cup_preview_path(format: :pdf), params: { team_id: team.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body).to start_with('%PDF')
    end

    it 'redirects when ranking data is empty' do
      team = FactoryBot.create(:team)
      allow(GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesCup::RankingCalculator, call: []))

      get compute_goggles_cup_preview_path(format: :pdf), params: { team_id: team.id, swimmer_ids: ['1'] }

      expect(response).to redirect_to(goggles_cup_preview_path(team_id: team.id.to_s))
    end
  end

  def ranking_row
    {
      swimmer_id: 1,
      swimmer_name: 'TEST SWIMMER',
      swimmer_year_of_birth: 1980,
      overall_score: 1000.0,
      top_rows: []
    }
  end

  def ranking_row_with_top_rows
    row = OpenStruct.new(
      event_type_code: '100SL',
      pool_type_code: '25',
      meeting_date: '2025-01-15',
      meeting_name: 'Test Meeting',
      meeting_id: 42,
      meeting_individual_result_id: 99,
      total_hundredths: 6500,
      old_meeting_date: '2024-01-10',
      old_meeting_name: 'Old Meeting',
      old_meeting_id: 30,
      old_meeting_individual_result_id: 88,
      old_total_hundredths: 7000
    )
    {
      swimmer_id: 1,
      swimmer_name: 'TEST SWIMMER',
      swimmer_year_of_birth: 1980,
      overall_score: 1076.92,
      top_rows: [{ row: row, row_score: 1076.92 }]
    }
  end
end
