# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 2 (Teams) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(temp_dir, 'test_source.json') }
    let(:phase2_file) { source_file.sub('.json', '-phase2.json') }
    let(:season) { FactoryBot.create(:season) }
    let(:city) { FactoryBot.create(:city) }
    let(:team) { FactoryBot.create(:team, city: city) }

    before(:each) do
      sign_in_admin(admin_user)
      # Create a minimal source file
      File.write(source_file, JSON.generate({ 'layoutType' => 4, 'teams' => { 'Team A' => 'Team A' } }))
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    describe 'GET /data_fix/review_teams with phase2_v2=1' do
      before(:each) do
        # Create phase2 file with test data (including fuzzy_matches)
        phase2_data = {
          'season_id' => season.id,
          'teams' => [
            { 'key' => 'Team Alpha', 'name' => 'Team Alpha', 'editable_name' => 'Team Alpha',
              'team_id' => nil, 'fuzzy_matches' => [] },
            { 'key' => 'Team Beta', 'name' => 'Team Beta', 'editable_name' => 'Team Beta',
              'team_id' => team.id, 'fuzzy_matches' => [{ 'id' => team.id, 'display_label' => team.editable_name }] },
            { 'key' => 'Team Gamma', 'name' => 'Team Gamma', 'editable_name' => 'Team Gamma',
              'team_id' => nil, 'fuzzy_matches' => [] }
          ]
        }
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: phase2_data, meta: { 'generator' => 'test' })
      end

      it 'loads the phase2 view successfully' do
        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response).to be_successful
        expect(response.body).to include('Step 2: Teams')
      end

      it 'displays all teams from phase file' do
        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response.body).to include('Team Alpha')
        expect(response.body).to include('Team Beta')
        expect(response.body).to include('Team Gamma')
      end

      it 'shows visual indicator for new teams (no DB ID)' do
        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response.body).to include('bg-light-yellow') # New team indicator
        expect(response.body).to include('fa-plus-circle') # Icon for new teams
        expect(response.body).to include('badge-primary') # NEW badge
      end

      it 'shows visual indicator for matched teams (with DB ID)' do
        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response.body).to include('bg-light') # Matched team indicator
        expect(response.body).to include('fa-check-circle') # Icon for matched teams
        expect(response.body).to include('badge-success') # ID badge
      end

      it 'displays empty teams message when no teams exist' do
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: { 'teams' => [] }, meta: { 'generator' => 'test' })

        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response.body).to include('No teams found')
      end

      it 'paginates teams correctly' do
        # Add more teams to test pagination
        teams = (1..55).map do |i|
          { 'key' => "Team #{i}", 'name' => "Team #{i}", 'editable_name' => "Team #{i}", 'team_id' => nil }
        end
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: { 'teams' => teams }, meta: { 'generator' => 'test' })

        get review_teams_path(file_path: source_file, phase2_v2: 1, teams_per_page: 25, teams_page: 1)
        expect(response).to be_successful
        # Check that we show first page teams (pagination is working)
        expect(response.body).to include('Team 1')
        expect(response.body).to include('Team 25')
        expect(response.body).not_to include('Team 26') # Should not show items from page 2
      end

      it 'filters teams by search query' do
        get review_teams_path(file_path: source_file, phase2_v2: 1, q: 'Alpha')
        expect(response).to be_successful
        expect(response.body).to include('Team Alpha')
        expect(response.body).not_to include('Team Beta')
      end

      it 'rescans and rebuilds phase2 file when rescan param is present' do
        # Delete phase file to force rescan
        FileUtils.rm_f(phase2_file)

        expect(Import::Solvers::TeamSolver).to receive(:new).with(season: anything).and_call_original

        get review_teams_path(file_path: source_file, phase2_v2: 1, rescan: '1')
        # After rescan, redirects without rescan parameter to prevent cascading rescans
        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))
        expect(File.exist?(phase2_file)).to be true
      end

      it 'displays fuzzy matches dropdown when matches exist' do
        # Add fuzzy matches to a team
        pfm = PhaseFileManager.new(phase2_file)
        data = pfm.data
        data['teams'][0]['fuzzy_matches'] = [
          { 'id' => 123, 'display_label' => 'Matched Team (ID: 123, City A)' },
          { 'id' => 456, 'display_label' => 'Another Team (ID: 456, City B)' }
        ]
        pfm.write!(data: data, meta: pfm.meta)

        get review_teams_path(file_path: source_file, phase2_v2: 1)
        expect(response).to be_successful
        expect(response.body).to include('Quick match selection')
        expect(response.body).to include('Matched Team (ID: 123, City A)')
      end
    end

    describe 'TeamSolver fuzzy matching' do
      it 'finds and stores fuzzy matches for each team' do
        # Create some teams in DB with similar names
        FactoryBot.create(:team, name: 'Swimming Club Alpha', editable_name: 'SC Alpha')
        FactoryBot.create(:team, name: 'Alpha Team', editable_name: 'Alpha Team')

        # Delete existing phase file
        FileUtils.rm_f(phase2_file)

        # Trigger rescan (which runs TeamSolver)
        get review_teams_path(file_path: source_file, phase2_v2: 1, rescan: '1')

        # Check that fuzzy matches were stored
        pfm = PhaseFileManager.new(phase2_file)
        teams = pfm.data['teams']
        team_alpha = teams.find { |t| t['key'] == 'Team A' }

        expect(team_alpha).to be_present
        expect(team_alpha['fuzzy_matches']).to be_an(Array)
      end

      it 'includes fuzzy_matches field in team data structure' do
        # Rebuild phase file
        FileUtils.rm_f(phase2_file)
        get review_teams_path(file_path: source_file, phase2_v2: 1, rescan: '1')

        # Check that fuzzy_matches field exists in structure
        pfm = PhaseFileManager.new(phase2_file)
        teams = pfm.data['teams']
        team_a = teams.find { |t| t['key'] == 'Team A' }

        expect(team_a).to have_key('fuzzy_matches')
        expect(team_a['fuzzy_matches']).to be_an(Array)
      end

      it 'auto-assignment logic works with fuzzy match weights' do
        # This test verifies the auto_assignable? logic with Jaro-Winkler weights
        # Simple rule: weight >= 0.90 → auto-assign
        solver = Import::Solvers::TeamSolver.new(season: season)

        # Test 1: High weight (>= 0.90) should auto-assign
        high_weight_match = {
          'id' => 123,
          'name' => 'Team Alpha',
          'editable_name' => 'Team Alpha',
          'weight' => 0.96
        }
        expect(solver.send(:auto_assignable?, high_weight_match, 'Team Alfa')).to be true

        # Test 2: Weight at threshold (0.90) should auto-assign
        threshold_match = {
          'id' => 124,
          'name' => 'Team A',
          'editable_name' => 'Team A',
          'weight' => 0.90
        }
        expect(solver.send(:auto_assignable?, threshold_match, 'Team A')).to be true

        # Test 3: Weight below threshold should NOT auto-assign
        low_weight_match = {
          'id' => 125,
          'name' => 'Team A Plus',
          'editable_name' => 'Team A+',
          'weight' => 0.89
        }
        expect(solver.send(:auto_assignable?, low_weight_match, 'Team A')).to be false

        # Test 4: Very low weight should NOT auto-assign
        very_low_weight = {
          'id' => 126,
          'name' => 'Completely Different Team',
          'editable_name' => 'Different',
          'weight' => 0.45
        }
        expect(solver.send(:auto_assignable?, very_low_weight, 'Team A')).to be false
      end
    end

    describe 'PATCH /data_fix/update_phase2_team' do
      before(:each) do
        phase2_data = {
          'season_id' => season.id,
          'teams' => [
            { 'key' => 'Team Original', 'name' => 'Team Original', 'editable_name' => 'Team Original',
              'name_variations' => nil, 'team_id' => nil, 'city_id' => nil }
          ]
        }
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: phase2_data, meta: { 'generator' => 'test' })
      end

      it 'updates team name field' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { name: 'Team Updated' }
          }
        }
        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['name']).to eq('Team Updated')
      end

      it 'updates editable_name field' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { editable_name: 'Team Display Name' }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['editable_name']).to eq('Team Display Name')
      end

      it 'updates name_variations field' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { name_variations: 'Variation1|Variation2|Variation3' }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['name_variations']).to eq('Variation1|Variation2|Variation3')
      end

      it 'updates team_id field from AutoComplete' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { team_id: team.id.to_s }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['team_id']).to eq(team.id)
      end

      it 'updates city_id field from City AutoComplete' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { city_id: city.id.to_s }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['city_id']).to eq(city.id)
      end

      it 'updates all fields at once' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => {
              name: 'Complete Update',
              editable_name: 'Complete Display',
              name_variations: 'Var1|Var2',
              team_id: team.id.to_s,
              city_id: city.id.to_s
            }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        updated_team = pfm.data['teams'][0]
        expect(updated_team['name']).to eq('Complete Update')
        expect(updated_team['editable_name']).to eq('Complete Display')
        expect(updated_team['name_variations']).to eq('Var1|Var2')
        expect(updated_team['team_id']).to eq(team.id)
        expect(updated_team['city_id']).to eq(city.id)
      end

      it 'handles nil city_id correctly' do
        # First set a city_id
        pfm = PhaseFileManager.new(phase2_file)
        data = pfm.data
        data['teams'][0]['city_id'] = city.id
        pfm.write!(data: data, meta: pfm.meta)

        # Then clear it
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { city_id: '' }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['city_id']).to be_nil
      end

      it 'sanitizes string inputs' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { name: '  Team With Spaces  ' }
          }
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['teams'][0]['name']).to eq('Team With Spaces')
      end

      it 'updates metadata timestamp' do
        original_pfm = PhaseFileManager.new(phase2_file)
        original_time = original_pfm.meta['generated_at']

        sleep 0.01 # Ensure timestamp difference

        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 0,
          team: {
            '0' => { name: 'Updated' }
          }
        }

        new_pfm = PhaseFileManager.new(phase2_file)
        expect(new_pfm.meta['generated_at']).not_to eq(original_time)
      end

      it 'rejects invalid team_index (negative)' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: -1,
          team: { '0' => { name: 'Test' } }
        }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'rejects invalid team_index (out of range)' do
        patch update_phase2_team_path, params: {
          file_path: source_file,
          team_index: 999,
          team: { '999' => { name: 'Test' } }
        }

        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))
        expect(flash[:warning]).to be_present
      end

      it 'rejects missing file_path' do
        patch update_phase2_team_path, params: {
          team_index: 0,
          team: { '0' => { name: 'Test' } }
        }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'POST /data_fix/add_team' do
      before(:each) do
        phase2_data = {
          'season_id' => season.id,
          'teams' => [
            { 'key' => 'Existing Team', 'name' => 'Existing Team', 'editable_name' => 'Existing Team' }
          ]
        }
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: phase2_data, meta: { 'generator' => 'test' })
      end

      it 'adds a new blank team to the phase file' do
        post data_fix_add_team_path, params: { file_path: source_file }

        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))

        pfm = PhaseFileManager.new(phase2_file)
        teams = pfm.data['teams']
        expect(teams.size).to eq(2)
      end

      it 'creates team with all required fields' do
        post data_fix_add_team_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase2_file)
        new_team = pfm.data['teams'].last

        expect(new_team['key']).to be_present
        expect(new_team['name']).to be_present
        expect(new_team['editable_name']).to be_present
        expect(new_team['team_id']).to be_nil
        expect(new_team['city_id']).to be_nil
      end

      it 'increments team index in name' do
        post data_fix_add_team_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase2_file)
        new_team = pfm.data['teams'].last

        expect(new_team['name']).to include('Team 2')
      end

      it 'updates metadata timestamp' do
        post data_fix_add_team_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.meta['generated_at']).to be_present
      end

      it 'rejects missing file_path' do
        post data_fix_add_team_path, params: {}

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'DELETE /data_fix/delete_team' do
      before(:each) do
        phase2_data = {
          'season_id' => season.id,
          'teams' => [
            { 'key' => 'Team 1', 'name' => 'Team 1', 'editable_name' => 'Team 1' },
            { 'key' => 'Team 2', 'name' => 'Team 2', 'editable_name' => 'Team 2' },
            { 'key' => 'Team 3', 'name' => 'Team 3', 'editable_name' => 'Team 3' }
          ],
          'swimmers' => [{ 'name' => 'Swimmer 1' }], # Downstream data that should be cleared
          'meeting_event' => [{ 'id' => 1 }]
        }
        pfm = PhaseFileManager.new(phase2_file)
        pfm.write!(data: phase2_data, meta: { 'generator' => 'test' })
      end

      it 'deletes the specified team' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: 1
        }

        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))

        pfm = PhaseFileManager.new(phase2_file)
        teams = pfm.data['teams']
        expect(teams.size).to eq(2)
        expect(teams.map { |t| t['name'] }).to eq(['Team 1', 'Team 3'])
      end

      it 'clears downstream swimmers data' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: 0
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['swimmers']).to eq([])
      end

      it 'clears downstream event data' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: 0
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.data['meeting_event']).to eq([])
      end

      it 'updates metadata timestamp' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: 0
        }

        pfm = PhaseFileManager.new(phase2_file)
        expect(pfm.meta['generated_at']).to be_present
      end

      it 'rejects invalid team_index (negative)' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: -1
        }

        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))
        expect(flash[:warning]).to include('Invalid team index')
      end

      it 'rejects invalid team_index (out of range)' do
        delete data_fix_delete_team_path, params: {
          file_path: source_file,
          team_index: 999
        }

        expect(response).to redirect_to(review_teams_path(file_path: source_file, phase2_v2: 1))
        expect(flash[:warning]).to include('Invalid team index')
      end

      it 'rejects missing file_path' do
        delete data_fix_delete_team_path, params: { team_index: 0 }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'rejects missing team_index' do
        delete data_fix_delete_team_path, params: { file_path: source_file }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'Phase 2 redirect to legacy' do
      it 'redirects to legacy controller when phase2_v2 param is absent' do
        get review_teams_path(file_path: source_file)

        expect(response).to have_http_status(:redirect)
        expect(response.location).to include('/data_fix_legacy/review_teams')
      end
    end
  end
end
