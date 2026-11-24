# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIMeetingsController do
  describe 'GET api_meetings (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_meetings_path)
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
          method: :get, url: 'meetings', jwt: admin_user.jwt,
          params: {
            name: anything, description: anything,
            header_date: anything, header_year: anything,
            season_id: anything,
            page: anything, per_page: anything
          }
        ).and_return(DummyResponse.new(body: GogglesDb::Meeting.first(25).to_json))
        get(api_meetings_path)
      end

      it 'returns http success' do
        expect(response).to have_http_status(:success)
      end

      it 'links a board-season meeting to its Season board row and each meeting to its season calendars (drill-down)' do
        board_meeting = FactoryBot.create(:meeting, season: SeasonDefaults.default_season)
        FactoryBot.create(:calendar, meeting: board_meeting, results_code: '987654')
        other_meeting = FactoryBot.create(:meeting)
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: [board_meeting, other_meeting].to_json))
        get(api_meetings_path)

        cells = response.parsed_body.css('table.datagrid-table tbody tr td[data-column="drill"]')
        expect(cells.size).to eq(2)
        expect(cells.first.at_css('a[data-drill="season_board"]')['href']).to eq(SeasonBoard::ActionPaths.board_row_path('987654'))
        expect(cells.last.at_css('a[data-drill="season_board"]')).to be_nil
        expect(cells.last.at_css('a[data-drill="calendars"]')['href'])
          .to eq(api_calendars_path(calendars_grid: { season_id: other_meeting.season_id }))
      end

      it 'links a board-season meeting without a FIN event id to the Season board itself' do
        board_meeting = FactoryBot.create(:meeting, season: SeasonDefaults.default_season)
        expect(MeetingsGrid.board_links_for([board_meeting])).to eq(board_meeting.id => season_board_path)
      end
    end

    it_behaves_like('an API grid index showing an API error in place', 'meetings') do
      let(:index_path) { api_meetings_path }
      let(:api_params) do
        { name: anything, description: anything, header_date: anything, header_year: anything,
          season_id: anything, page: anything, per_page: anything }
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_meeting (update)' do
    let(:fixture_row) { FactoryBot.create(:meeting) }
    let(:new_value) { GogglesDb::Season.pluck(:id).first(100).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_meeting_path(fixture_row.id), params: { season_id: new_value })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :put, url: "meeting/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_meeting_path(fixture_row.id), params: { season_id: new_value })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_meetings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_meetings/clone' do
    let(:clone_source_id) { GogglesDb::Meeting.pluck(:id).last(200).sample }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_meetings_clone_path, params: { id: clone_source_id })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :post, url: "meeting/clone/#{clone_source_id}", jwt: admin_user.jwt
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(api_meetings_clone_path, params: { id: clone_source_id })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_meetings_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
