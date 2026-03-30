# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HomeController do
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

      it 'shows data-fix session count from distinct phase_file_path values' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all
        GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'home-a-1', phase_file_path: '/tmp/a.json')
        GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'home-a-2', phase_file_path: '/tmp/a.json')
        GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'home-b-1', phase_file_path: '/tmp/b.json')
        GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'home-blank', phase_file_path: nil)

        get(home_index_path)

        expect(response.body).to include('Data-Fix v2 sessions: 2')
      end

      it 'shows clean-slate button when at least one session exists' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all
        GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'home-c-1', phase_file_path: '/tmp/c.json')

        get(home_index_path)

        expect(response.body).to include('Clean slate')
      end

      it 'hides clean-slate button when no sessions exist' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all

        get(home_index_path)

        expect(response.body).to include('Data-Fix v2 sessions: 0')
        expect(response.body).not_to include('Clean slate')
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
