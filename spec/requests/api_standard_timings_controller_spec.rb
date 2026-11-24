# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIStandardTimingsController do
  describe 'GET api_standard_timings (index)' do
    let(:api_params) do
      { season_id: anything, gender_type_id: anything, pool_type_id: anything, event_type_id: anything,
        category_type_id: anything, page: anything, per_page: anything }
    end

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_standard_timings_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      let(:rows) { GogglesDb::StandardTiming.first(5) }

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call).with(method: :get, url: 'standard_timings', jwt: admin_user.jwt, params: api_params)
                                         .and_return(DummyResponse.new(body: rows.to_json))
        get(api_standard_timings_path)
      end

      it 'returns http success with one grid row per standard timing' do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body.css('table.datagrid-table tbody tr').size).to eq(rows.size)
      end
    end

    it_behaves_like('an API grid index showing an API error in place', 'standard_timings') do
      let(:index_path) { api_standard_timings_path }
    end
  end
end
