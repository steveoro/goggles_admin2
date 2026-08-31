# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PullController do
  describe 'GET /index' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get '/pull/index'
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
        get '/pull/index'
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /run_crawler_api' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
      allow(RestClient::Request).to receive(:execute).and_return(double(body: '{}'))
    end

    it 'routes a layout-2 direct FIN URL to /pull_results with meeting_url' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 2,
        target_url: 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/123',
        sub_menu_type: 'Eventi',
        target_event: ''
      }

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(
          url: 'http://localhost:7000/pull_results',
          headers: hash_including(
            'params' => hash_including(
              'season_id' => '242',
              'layout' => 2,
              'meeting_url' => 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/123'
            ),
            'Content-Type' => 'application/json'
          )
        )
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'routes a layout-4 URL to /pull_results_microplus' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 4,
        target_url: 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php',
        sub_menu_type: 'Eventi'
      }

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(url: 'http://localhost:7000/pull_results_microplus')
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'rejects a layout-2 request with the placeholder still in target_url' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 2,
        target_url: 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/ (+<LINK>)',
        sub_menu_type: 'Eventi'
      }

      expect(RestClient::Request).not_to have_received(:execute)
      expect(response).to redirect_to(pull_index_path)
      expect(flash[:warning]).to be_present
    end
  end
end
