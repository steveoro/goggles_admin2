# frozen_string_literal: true

require 'rails_helper'

# Shared Data-Fix lookups (moved here from the retired legacy wizard in 0.10.80).
RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'GET /data_fix/coded_name' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(data_fix_coded_name_path, params: { target: 'code', description: 'Trofeo Test', city_name: 'Reggio Emilia' },
                                      headers: { 'Accept' => 'application/json' })
        expect(response).to have_http_status(:unauthorized).or redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      before(:each) { sign_in_admin(prepare_admin_user) }

      it 'returns the Meeting code for the "code" target' do
        get(data_fix_coded_name_path, params: { target: 'code', description: '7° Trofeo Città di Reggio', city_name: 'Reggio Emilia' },
                                      headers: { 'Accept' => 'application/json' })

        expect(response).to be_successful
        expected = GogglesDb::Normalizers::CodedName.for_meeting('7° Trofeo Città di Reggio', 'Reggio Emilia')
        expect(response.parsed_body).to eq('code' => expected)
        expect(expected).to be_present
      end

      it 'returns the SwimmingPool nick_name for the "nick_name" target' do
        get(data_fix_coded_name_path, params: { target: 'nick_name', name: 'Piscina Comunale', city_name: 'Parma', pool_type_code: '25' },
                                      headers: { 'Accept' => 'application/json' })

        expect(response).to be_successful
        expected = GogglesDb::Normalizers::CodedName.for_pool('Piscina Comunale', 'Parma', '25')
        expect(response.parsed_body).to eq('nick_name' => expected)
        expect(expected).to be_present
      end

      it 'refuses an unknown target with a redirect' do
        get(data_fix_coded_name_path, params: { target: 'bogus' }, headers: { 'Accept' => 'application/json' })

        expect(response).to redirect_to(root_path)
      end

      it 'refuses a non-JSON request with a redirect' do
        get(data_fix_coded_name_path, params: { target: 'code', description: 'Trofeo Test', city_name: 'Parma' })

        expect(response).to redirect_to(root_path)
        expect(flash[:warning]).to eq(I18n.t('data_import.errors.invalid_request'))
      end
    end
  end

  describe 'GET /data_fix/teams_for_swimmer/:swimmer_id' do
    before(:each) { sign_in_admin(prepare_admin_user) }

    let(:badge) { GogglesDb::Badge.joins(:team).includes(:team).first }

    it 'updates the team list target with the swimmer teams (turbo stream)' do
      expect(badge).to be_present

      get(data_fix_teams_for_swimmer_path(swimmer_id: badge.swimmer_id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' })

      expect(response).to be_successful
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include(%(<turbo-stream action="update" target="team-list-for-#{badge.swimmer_id}">))
      expect(response.body).to include(ERB::Util.html_escape("#{badge.team.editable_name} (#{badge.team_id})"))
    end

    it 'renders an empty list for a swimmer without badges' do
      get(data_fix_teams_for_swimmer_path(swimmer_id: 0), headers: { 'Accept' => 'text/vnd.turbo-stream.html' })

      expect(response).to be_successful
      expect(response.body).to include('target="team-list-for-0"')
      expect(response.body).to include('<template></template>')
    end

    it 'refuses a non turbo-stream request with a redirect' do
      get(data_fix_teams_for_swimmer_path(swimmer_id: 1))

      expect(response).to redirect_to(root_path)
    end
  end
end
