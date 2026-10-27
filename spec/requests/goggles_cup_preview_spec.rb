# frozen_string_literal: true

require 'ostruct'
require 'rails_helper'

RSpec.describe 'GogglesCupPreview' do
  # Stubs APIProxy.call so remote mutations return a Result double carrying
  # +json+ and +code+; the actual sync payload then flows through
  # SyncCupToLocal into the local DB, mirroring production behavior.
  def stub_cup_api(json: {}, code: 200)
    response = instance_double(
      RestClient::Response, code:, body: json.to_json, headers: {}
    )
    result = APIProxy::Result.new(response)
    allow(APIProxy).to receive(:call).and_return(result)
    result
  end

  # Remote-"echo" sync payload for +cup+: what the API would return after
  # writing (or reading) the same row remotely.
  def sync_block_for(cup, overrides = {})
    {
      'goggle_cup' => cup.attributes.merge(overrides.stringify_keys),
      'team_affiliation' => nil,
      'badges' => []
    }
  end
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
        query = instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: [swimmer_option])
        allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(query)

        get goggles_cup_preview_path, params: { team_id: team.id }

        expect(response).to have_http_status(:success)
        expect(response.body).to include('TEST SWIMMER')
      end

      it 'renders the season year selector including the current cup years' do
        team = FactoryBot.create(:team)
        FactoryBot.create(:goggle_cup, team: team, description: 'Old Cup', season_year: 2020)
        allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))

        get goggles_cup_preview_path, params: { team_id: team.id, season_year: 2020 }

        expect(response.body).to include('id="season_year_select"')
        expect(response.body).to include('>2020</option>')
      end

      it 'limits the cup selector to the cups of the shown season year' do
        team = FactoryBot.create(:team)
        FactoryBot.create(:goggle_cup, team: team, description: 'Cup 2020', season_year: 2020)
        FactoryBot.create(:goggle_cup, team: team, description: 'Cup 2021', season_year: 2021)
        allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))

        get goggles_cup_preview_path, params: { team_id: team.id, season_year: 2020 }

        expect(response.body).to include('Cup 2020')
        expect(response.body).not_to include('Cup 2021')
      end

      it 'always lists the current MASFIN championship year in the selector' do
        team = FactoryBot.create(:team)
        FactoryBot.create(:goggle_cup, team: team, description: 'Cup 2020', season_year: 2020)
        allow(GogglesDb::Season).to receive(:current_championship_year).and_return(2035)
        allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))

        get goggles_cup_preview_path, params: { team_id: team.id, season_year: 2020 }

        expect(response.body).to include('>2035</option>')
        expect(response.body).to include('>2020</option>')
      end

      it 'resolves the default shown year from the ongoing MASFIN season' do
        team = FactoryBot.create(:team)
        allow(GogglesDb::Season).to receive(:current_championship_year).and_return(2035)
        allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))

        get goggles_cup_preview_path, params: { team_id: team.id }

        expect(GogglesDb::Season).to have_received(:current_championship_year).with(GogglesDb::SeasonType.mas_fin)
        expect(response.body).to include('>2035</option>')
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
      query = instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, smart_selected_ids_for: [10, 20])
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(query)

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
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesDb::GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::RankingCalculator, call: [ranking_row]))

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
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesDb::GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::RankingCalculator,
                                                                                                  call: [ranking_row_with_top_rows]))

      get compute_goggles_cup_preview_path(format: :pdf), params: { team_id: team.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body).to start_with('%PDF')
    end

    it 'redirects when ranking data is empty' do
      team = FactoryBot.create(:team)
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      allow(GogglesDb::GogglesCup::RankingCalculator).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::RankingCalculator, call: []))

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
    row = Struct.new(
      :event_type_code, :pool_type_code, :meeting_date, :meeting_name, :meeting_id,
      :meeting_individual_result_id, :total_hundredths,
      :old_meeting_date, :old_meeting_name, :old_meeting_id,
      :old_meeting_individual_result_id, :old_total_hundredths
    ).new(
      '100SL', '25', '2025-01-15', 'Test Meeting', 42,
      99, 6500,
      '2024-01-10', 'Old Meeting', 30,
      88, 7000
    )
    {
      swimmer_id: 1,
      swimmer_name: 'TEST SWIMMER',
      swimmer_year_of_birth: 1980,
      overall_score: 1076.92,
      top_rows: [{ row: row, row_score: 1076.92 }]
    }
  end

  describe 'GET /best_results/goggles_cup_preview with a stored cup' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    def stored_cup(swimmer, team, ranking_data: nil)
      FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025,
                                     swimmers_ids: swimmer.id.to_s).tap do |cup|
        cup.update!(ranking_data: ranking_data || {
          description: 'Test Cup', season_year: 2025, max_points: 1000, team_id: team.id,
          end_date: '2026-07-31', swimmer_ids: [swimmer.id], no_duplicated_events: false,
          data: {
            base_timings: {},
            scores: {
              swimmer.id.to_s => [
                { 'event_type_code' => '50SL', 'pool_type_code' => '25', 'total_hundredths' => 3000,
                  'meeting_date' => '2025-01-15', 'meeting_name' => 'Test Meeting', 'meeting_id' => 42,
                  'meeting_individual_result_id' => 99, 'team_id' => team.id, 'team_name' => 'TEST',
                  'old_total_hundredths' => 3200, 'old_meeting_date' => '2024-01-10',
                  'old_meeting_name' => 'Old Meeting', 'old_meeting_id' => 30,
                  'old_meeting_individual_result_id' => 88, 'row_score' => 1066.67 }
              ]
            }
          }
        }.to_json)
      end
    end

    it 'renders the stored ranking and a read-only swimmer selection' do
      team = FactoryBot.create(:team)
      swimmer = FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980)
      cup = stored_cup(swimmer, team)
      query = instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery,
                              call: [{ swimmer_id: swimmer.id, swimmer_name: 'TEST SWIMMER', swimmer_year_of_birth: 1980 }])
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(query)

      get goggles_cup_preview_path, params: { goggle_cup_id: cup.id }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('TEST SWIMMER')
      # read-only markers: hint, badge & edit-selection button (checkboxes are disabled)
      expect(response.body).to include("id='swimmer-list-readonly-hint'")
      expect(response.body).to include("id='badge-readonly'")
      expect(response.body).to include('id="btn-edit-swimmers"')
      expect(response.body).to include('disabled="disabled" data-goggles-cup-target="swimmerCheckbox"')
    end

    it 'renders an editable swimmer selection when the cup has no ranking_data' do
      team = FactoryBot.create(:team)
      swimmer = FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Empty Cup', season_year: 2025,
                                           swimmers_ids: swimmer.id.to_s)
      query = instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery,
                              call: [{ swimmer_id: swimmer.id, swimmer_name: 'TEST SWIMMER', swimmer_year_of_birth: 1980 }])
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(query)

      get goggles_cup_preview_path, params: { goggle_cup_id: cup.id }

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('id="btn-edit-swimmers"')
      expect(response.body).not_to include("id='swimmer-list-readonly-hint'")
      expect(response.body).not_to include("id='badge-readonly'")
      expect(response.body).not_to include('disabled="disabled" data-goggles-cup-target="swimmerCheckbox"')
    end
  end

  describe 'POST /best_results/goggles_cup_preview/clear_ranking' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'clears the stored ranking_data and redirects back to the cup page' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      cup.update!(ranking_data: { test: 'data' }.to_json)
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'ranking_data' => nil) })

      post clear_ranking_goggles_cup_preview_path, params: { goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id))
      expect(cup.reload.ranking_data).to be_nil
      expect(flash[:notice]).to be_present
    end

    it 'redirects without changes when the cup has no ranking_data' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Empty Cup', season_year: 2025, swimmers_ids: '1')

      post clear_ranking_goggles_cup_preview_path, params: { goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id))
      expect(flash[:notice]).to be_blank
    end
  end

  describe 'POST /best_results/goggles_cup_preview/save' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'creates a new GoggleCup remotely, mirrors it locally and redirects' do
      team = FactoryBot.create(:team)
      remote_id = GogglesDb::GoggleCup.maximum(:id).to_i + 100
      remote_attrs = FactoryBot.build(:goggle_cup, id: remote_id, team: team, description: 'New Cup',
                                                   season_year: 2025, swimmers_ids: '1,2,3').attributes
      stub_cup_api(
        json: { 'cup' => remote_attrs, 'badges_report' => { 'created' => [], 'skipped' => [] },
                'sync' => { 'goggle_cup' => remote_attrs, 'team_affiliation' => nil, 'badges' => [] } }
      )

      expect do
        post save_goggles_cup_preview_path, params: {
          team_id: team.id,
          description: 'New Cup',
          season_year: 2025,
          end_date: '2026-07-31',
          swimmer_ids: %w[1 2 3]
        }
      end.to change(GogglesDb::GoggleCup, :count).by(1)

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: remote_id,
                                                               season_year: '2025', team_id: team.id.to_s))
      cup = GogglesDb::GoggleCup.find(remote_id)
      expect(cup.description).to eq('New Cup')
      expect(cup.swimmers_ids).to eq('1,2,3')
    end

    it 'updates an existing GoggleCup remotely and mirrors it locally' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Old', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'description' => 'Updated', 'swimmers_ids' => '1,2') })

      post save_goggles_cup_preview_path, params: {
        team_id: team.id,
        goggle_cup_id: cup.id,
        description: 'Updated',
        season_year: 2025,
        end_date: '2026-07-31',
        swimmer_ids: %w[1 2]
      }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id,
                                                               season_year: '2025', team_id: team.id.to_s))
      cup.reload
      expect(cup.description).to eq('Updated')
      expect(cup.swimmers_ids).to eq('1,2')
    end

    it 'clears the stored ranking_data when the swimmer selection changes' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1,2')
      cup.update!(ranking_data: { test: 'data' }.to_json)
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'swimmers_ids' => '1', 'ranking_data' => nil) })

      post save_goggles_cup_preview_path, params: {
        team_id: team.id,
        goggle_cup_id: cup.id,
        description: 'Test Cup',
        season_year: 2025,
        end_date: '2026-07-31',
        swimmer_ids: %w[1]
      }

      cup.reload
      expect(cup.swimmers_ids).to eq('1')
      expect(cup.ranking_data).to be_nil
    end

    it 'keeps the stored ranking_data when the swimmer selection is unchanged' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1,2')
      stored_data = { test: 'data' }.to_json
      cup.update!(ranking_data: stored_data)
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'description' => 'Renamed Cup') })

      post save_goggles_cup_preview_path, params: {
        team_id: team.id,
        goggle_cup_id: cup.id,
        description: 'Renamed Cup',
        season_year: 2025,
        end_date: '2026-07-31',
        swimmer_ids: %w[2 1]
      }

      cup.reload
      expect(cup.description).to eq('Renamed Cup')
      expect(cup.ranking_data).to eq(stored_data)
    end

    it 'shows the API error when the remote save fails' do
      team = FactoryBot.create(:team)
      stub_cup_api(json: { 'error' => 'remote rejected' }, code: 422)

      post save_goggles_cup_preview_path, params: {
        team_id: team.id,
        description: 'New Cup',
        season_year: 2025,
        end_date: '2026-07-31',
        swimmer_ids: %w[1]
      }

      expect(response).to redirect_to(goggles_cup_preview_path(season_year: '2025', team_id: team.id.to_s))
      expect(flash[:alert]).to include('remote rejected')
    end

    it 'creates the cup remotely (POST) when the PUT finds no remote row' do
      team = FactoryBot.create(:team)
      local_cup = FactoryBot.create(:goggle_cup, team: team, description: 'Local Cup', season_year: 2025)
      remote_attrs = local_cup.attributes.merge('id' => GogglesDb::GoggleCup.maximum(:id).to_i + 100)
      not_found = APIProxy::Result.new(instance_double(RestClient::Response, code: 404, body: '{}', headers: {}))
      created = APIProxy::Result.new(instance_double(RestClient::Response, code: 201, headers: {},
                                                                           body: { 'sync' => { 'goggle_cup' => remote_attrs } }.to_json))
      allow(APIProxy).to receive(:call).and_return(not_found, created)

      post save_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: local_cup.id, description: 'Local Cup',
                                                    season_year: 2025, end_date: '2026-07-31' }

      expect(APIProxy).to have_received(:call).with(hash_including(method: :put)).ordered
      expect(APIProxy).to have_received(:call).with(hash_including(method: :post, url: 'goggle_cup_manage')).ordered
      expect(flash[:notice]).to be_present
      expect(GogglesDb::GoggleCup.find_by(id: remote_attrs['id'])).to be_present
    end
  end

  describe 'POST /best_results/goggles_cup_preview/compute with goggle_cup_id' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'persists ranking_data JSON on the GoggleCup when computing with a cup id' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      ranking_json = {
        'description' => 'Test Cup', 'season_year' => 2025, 'team_id' => team.id,
        'swimmer_ids' => [1], 'no_duplicated_events' => false,
        'data' => { 'base_timings' => {}, 'scores' => {} }
      }.to_json
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'ranking_data' => ranking_json) })

      post compute_goggles_cup_preview_path(format: :json), params: { team_id: team.id, goggle_cup_id: cup.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:success)
      expect(cup.reload.ranking_data).to eq(ranking_json)
    end

    it 'redirects with an error when the remote compute fails' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      stub_cup_api(json: { 'error' => 'compute broke' }, code: 422)

      post compute_goggles_cup_preview_path(format: :html), params: { team_id: team.id, goggle_cup_id: cup.id, swimmer_ids: ['1'] }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:alert]).to include('compute broke')
    end

    it 'returns a JSON error (not a redirect) when the AJAX remote compute fails' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      stub_cup_api(json: { 'error' => 'compute broke' }, code: 422)

      post compute_goggles_cup_preview_path(format: :json), params: { team_id: team.id, goggle_cup_id: cup.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('compute broke')
    end

    it 'returns a JSON error when the API is unreachable' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      allow(RestClient::Request).to receive(:execute).and_raise(Errno::ECONNREFUSED)

      post compute_goggles_cup_preview_path(format: :json), params: { team_id: team.id, goggle_cup_id: cup.id, swimmer_ids: ['1'] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include(I18n.t('goggles_cup.api_unreachable', detail: '').strip)
    end

    it 'never calls the API for an export of a stored cup' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1',
                                           ranking_data: { 'no_duplicated_events' => false,
                                                           'data' => { 'base_timings' => {}, 'scores' => {} } }.to_json)
      allow(GogglesDb::GogglesCup::SwimmerOptionsQuery).to receive(:new).and_return(instance_double(GogglesDb::GogglesCup::SwimmerOptionsQuery, call: []))
      allow(APIProxy).to receive(:call)

      get compute_goggles_cup_preview_path(format: :csv), params: { team_id: team.id, goggle_cup_id: cup.id, swimmer_ids: ['1'] }

      expect(APIProxy).not_to have_received(:call)
    end
  end

  describe 'GET /best_results/goggles_cup_preview/compute (base timings CSV)' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'exports base timings from a stored cup as CSV' do
      team = FactoryBot.create(:team)
      swimmer = FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: swimmer.id.to_s)
      cup.update!(ranking_data: {
        description: 'Test Cup', season_year: 2025, max_points: 1000, team_id: team.id,
        end_date: '2026-07-31', swimmer_ids: [swimmer.id], no_duplicated_events: false,
        data: {
          base_timings: {
            swimmer.id.to_s => [
              { 'event_type_code' => '50SL', 'pool_type_code' => '25',
                'season_header_year' => 2022, 'total_hundredths' => 3100,
                'meeting_date' => '2022-02-01', 'meeting_name' => 'Base Meeting',
                'meeting_id' => 7, 'meeting_individual_result_id' => 777 }
            ]
          },
          scores: {
            swimmer.id.to_s => [
              { 'event_type_code' => '50SL', 'pool_type_code' => '25',
                'total_hundredths' => 3000, 'meeting_date' => '2025-01-15',
                'meeting_name' => 'Test Meeting', 'meeting_id' => 42,
                'meeting_individual_result_id' => 99, 'team_id' => team.id,
                'team_name' => 'TEST', 'old_total_hundredths' => 3200,
                'old_meeting_date' => '2024-01-10', 'old_meeting_name' => 'Old Meeting',
                'old_meeting_id' => 30, 'old_meeting_individual_result_id' => 88,
                'row_score' => 1066.67 }
            ]
          }
        }
      }.to_json)
      stub_cup_api(json: { 'sync' => sync_block_for(cup) })

      get compute_goggles_cup_preview_path(format: :csv), params: { team_id: team.id, goggle_cup_id: cup.id, export_type: 'base_timings' }

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('text/csv')
      expect(response.body).to include('TEST SWIMMER')
      expect(response.body).to include('50SL')
    end
  end

  describe 'POST /best_results/goggles_cup_preview/apply_local' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'redirects with an error when no cup is selected' do
      team = FactoryBot.create(:team)

      post apply_local_goggles_cup_preview_path, params: { team_id: team.id }

      expect(response).to redirect_to(goggles_cup_preview_path(team_id: team.id.to_s))
      expect(flash[:alert]).to be_present
    end

    it 'overwrites the local row with the remote one' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Local Stale', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'description' => 'Remote Fresh', 'swimmers_ids' => '1,2,3') })

      post apply_local_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:notice]).to be_present
      cup.reload
      expect(cup.description).to eq('Remote Fresh')
      expect(cup.swimmers_ids).to eq('1,2,3')
    end

    it 'surfaces the API error when the remote pull fails' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'error' => 'remote down' }, code: 502)

      post apply_local_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:alert]).to include('remote down')
    end

    it 'shows the apply-local button for any saved cup with swimmers' do
      team = FactoryBot.create(:team)
      cup_without = FactoryBot.create(:goggle_cup, team: team, description: 'Config Only', season_year: 2025, swimmers_ids: '1')
      cup_with = FactoryBot.create(:goggle_cup, team: team, description: 'Ready', season_year: 2026, swimmers_ids: '1')
      cup_with.update!(ranking_data: { test: 'data' }.to_json)

      get goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup_without.id }
      expect(response.body).to include(I18n.t('goggles_cup.apply_local'))
      expect(response.body).not_to include('btn btn-outline-secondary btn-lg w-100 d-none')

      get goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup_with.id }
      expect(response.body).to include(I18n.t('goggles_cup.apply_local'))
      expect(response.body).not_to include('btn btn-outline-secondary btn-lg w-100 d-none')
    end

    it 'hides the apply-local button when the cup has no swimmers' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'No Swimmers', season_year: 2025, swimmers_ids: nil)

      get goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }
      expect(response.body).to include(I18n.t('goggles_cup.apply_local'))
      expect(response.body).to include('btn btn-outline-secondary btn-lg w-100 d-none')
    end
  end

  describe 'POST /best_results/goggles_cup_preview/resync' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'pulls the remote row into the local mirror' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Stale', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'description' => 'Fresh') })

      post resync_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:notice]).to be_present
      expect(cup.reload.description).to eq('Fresh')
    end
  end

  describe 'POST /best_results/goggles_cup_preview/publish & unpublish' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'publishes the cup remotely and resyncs the local mirror' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'published' => true) })

      post publish_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:notice]).to be_present
      expect(cup.reload.published).to be(true)
    end

    it 'unpublishes the cup remotely and resyncs the local mirror' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025,
                                           swimmers_ids: '1', published: true)
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'published' => false) })

      post unpublish_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(cup.reload.published).to be(false)
    end

    it 'unpublishes the local sibling cup when mirroring a remote publish' do
      team = FactoryBot.create(:team)
      sibling = FactoryBot.create(:goggle_cup, team: team, description: 'Old Cup', season_year: 2025, published: true)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'New Cup', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'published' => true) })

      post publish_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(flash[:notice]).to be_present
      expect(cup.reload.published).to be(true)
      expect(sibling.reload.published).to be(false)
    end

    it 'flashes an alert instead of failing when the local mirror cannot be updated' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: '1')
      stub_cup_api(json: { 'sync' => sync_block_for(cup, 'published' => true) })
      allow(SyncCupToLocal).to receive(:call).and_raise(ActiveRecord::RecordInvalid)

      post publish_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to be_present
    end
  end

  describe 'GET /best_results/goggles_cup_preview/base_timings' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'renders the base timings page for a cup with stored ranking data' do
      team = FactoryBot.create(:team)
      swimmer = FactoryBot.create(:swimmer, complete_name: 'TEST SWIMMER', year_of_birth: 1980)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Test Cup', season_year: 2025, swimmers_ids: swimmer.id.to_s)
      cup.update!(ranking_data: {
        description: 'Test Cup', season_year: 2025, max_points: 1000, team_id: team.id,
        end_date: '2026-07-31', swimmer_ids: [swimmer.id], no_duplicated_events: false,
        data: {
          base_timings: {
            swimmer.id.to_s => [
              { 'event_type_code' => '50SL', 'pool_type_code' => '25',
                'season_header_year' => 2022, 'total_hundredths' => 3100,
                'meeting_date' => '2022-02-01', 'meeting_name' => 'Base Meeting',
                'meeting_id' => 7, 'meeting_individual_result_id' => 777 }
            ]
          },
          scores: {
            swimmer.id.to_s => [
              { 'event_type_code' => '50SL', 'pool_type_code' => '25',
                'total_hundredths' => 3000, 'meeting_date' => '2025-01-15',
                'meeting_name' => 'Test Meeting', 'meeting_id' => 42,
                'meeting_individual_result_id' => 99, 'team_id' => team.id,
                'team_name' => 'TEST', 'old_total_hundredths' => 3200,
                'old_meeting_date' => '2024-01-10', 'old_meeting_name' => 'Old Meeting',
                'old_meeting_id' => 30, 'old_meeting_individual_result_id' => 88,
                'row_score' => 1066.67 }
            ]
          }
        }
      }.to_json)

      get base_timings_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to have_http_status(:success)
      expect(response.body).to include(I18n.t('goggles_cup.base_timings.title'))
      expect(response.body).to include('TEST SWIMMER')
      expect(response.body).to include('50SL')
      expect(response.body).to include(I18n.t('goggles_cup.base_timings.back_to_ranking'))
    end

    it 'redirects when the cup has no ranking data' do
      team = FactoryBot.create(:team)
      cup = FactoryBot.create(:goggle_cup, team: team, description: 'Empty Cup', season_year: 2025, swimmers_ids: '1')

      get base_timings_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: cup.id }

      expect(response).to redirect_to(goggles_cup_preview_path(goggle_cup_id: cup.id, team_id: team.id.to_s))
      expect(flash[:alert]).to be_present
    end

    it 'redirects when the cup is missing' do
      team = FactoryBot.create(:team)

      get base_timings_goggles_cup_preview_path, params: { team_id: team.id, goggle_cup_id: 0 }

      expect(response).to redirect_to(goggles_cup_preview_path(team_id: team.id.to_s))
      expect(flash[:alert]).to be_present
    end
  end
end
