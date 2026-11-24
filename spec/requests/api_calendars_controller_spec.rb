# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APICalendarsController do
  describe 'GET api_calendars (index)' do
    let(:api_params) { { season_id: anything, page: anything, per_page: anything } }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_calendars_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      let(:rows) { GogglesDb::Calendar.where.not(season_id: nil).first(5) }

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call).with(method: :get, url: 'calendars', jwt: admin_user.jwt, params: api_params)
                                         .and_return(DummyResponse.new(body: rows.to_json))
        get(api_calendars_path)
      end

      it 'returns http success with one grid row per calendar' do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body.css('table.datagrid-table tbody tr').size).to eq(rows.size)
      end

      it 'links each row to the meetings grid filtered by the meeting name (drill-down link)' do
        link = response.parsed_body.at_css('td[data-column="meeting_lookup"] a[data-drill="meetings"]')
        expect(link['href']).to start_with(api_meetings_path)
        expect(link['data-bs-title']).to eq(I18n.t('datagrid.drill.meetings'))
      end
    end

    it_behaves_like('an API grid index showing an API error in place', 'calendars') do
      let(:index_path) { api_calendars_path }
    end
  end
end
