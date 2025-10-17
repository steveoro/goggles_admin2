# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 3 (Swimmers) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(temp_dir, 'test_source.json') }
    let(:phase3_file) { source_file.sub('.json', '-phase3.json') }
    let(:season) { FactoryBot.create(:season) }
    let(:swimmer) { FactoryBot.create(:swimmer) }
    let(:team) { FactoryBot.create(:team) }

    before(:each) do
      sign_in_admin(admin_user)
      # Create a minimal source file
      File.write(source_file, JSON.generate({ 'layoutType' => 4, 'swimmers' => { 'John Doe' => 'John Doe' } }))
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    describe 'GET /data_fix/review_swimmers with phase3_v2=1' do
      before(:each) do
        # Create phase3 file with test data (including fuzzy_matches)
        phase3_data = {
          'season_id' => season.id,
          'swimmers' => [
            { 'key' => 'ALPHA|JOHN|1985', 'last_name' => 'Alpha', 'first_name' => 'John',
              'year_of_birth' => 1985, 'gender_type_code' => 'M', 'complete_name' => 'Alpha John',
              'swimmer_id' => nil, 'fuzzy_matches' => [] },
            { 'key' => 'BETA|JANE|1990', 'last_name' => 'Beta', 'first_name' => 'Jane',
              'year_of_birth' => 1990, 'gender_type_code' => 'F', 'complete_name' => 'Beta Jane',
              'swimmer_id' => swimmer.id, 'fuzzy_matches' => [{ 'id' => swimmer.id, 'display_label' => "#{swimmer.complete_name} (1990, ID: #{swimmer.id}, match: 95%)" }] },
            { 'key' => 'GAMMA|BOB|1988', 'last_name' => 'Gamma', 'first_name' => 'Bob',
              'year_of_birth' => 1988, 'gender_type_code' => 'M', 'complete_name' => 'Gamma Bob',
              'swimmer_id' => nil, 'fuzzy_matches' => [] }
          ],
          'badges' => [
            { 'swimmer_key' => 'BETA|JANE|1990', 'team_key' => 'Team A', 'season_id' => season.id }
          ]
        }
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: phase3_data, meta: { 'generator' => 'test', 'generated_at' => Time.now.utc.iso8601 })
      end

      it 'loads the phase3 view successfully' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response).to be_successful
        expect(response.body).to include('Step 3: Swimmers')
      end

      it 'displays all swimmers from phase file' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Alpha John')
        expect(response.body).to include('Beta Jane')
        expect(response.body).to include('Gamma Bob')
      end

      it 'shows visual indicator for new swimmers (no DB ID)' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('bg-light-yellow') # New swimmer indicator
        expect(response.body).to include('badge-primary') # NEW badge
      end

      it 'shows visual indicator for matched swimmers (with DB ID)' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('bg-light') # Matched swimmer indicator
        expect(response.body).to include('badge-success') # ID badge
      end

      it 'displays empty swimmers message when no swimmers exist' do
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: { 'swimmers' => [] }, meta: { 'generator' => 'test' })

        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('No swimmers found')
      end

      it 'paginates swimmers correctly (default 100 per page)' do
        # Add more swimmers to test pagination
        swimmers = (1..120).map do |i|
          { 'key' => "SWIMMER#{i}|TEST|1990", 'last_name' => "Swimmer#{i}", 'first_name' => 'Test',
            'year_of_birth' => 1990, 'gender_type_code' => 'M', 'complete_name' => "Swimmer#{i} Test",
            'swimmer_id' => nil, 'fuzzy_matches' => [] }
        end
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: { 'swimmers' => swimmers }, meta: { 'generator' => 'test' })

        get review_swimmers_path(file_path: source_file, phase3_v2: 1, per_page: 100)
        expect(response.body).to include('Page')
        expect(response.body).to include('1..100') # Row range display
        expect(response.body).to include('Swimmer1 Test')
        expect(response.body).not_to include('Swimmer115 Test') # Beyond first page
      end

      it 'filters swimmers by name' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1, q: 'Beta')
        expect(response.body).to include('Beta Jane')
        expect(response.body).not_to include('Alpha John')
        expect(response.body).not_to include('Gamma Bob')
      end

      it 'displays phase metadata' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Phase Metadata')
        expect(response.body).to include('Generated at')
      end

      it 'shows AutoComplete component for swimmer lookup' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('autocomplete') # AutoComplete component present
      end

      it 'displays fuzzy matches dropdown when matches exist' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Quick match selection')
        expect(response.body).to include('fuzzy_select')
      end

      it 'shows Add Swimmer button' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Add Swimmer')
      end

      it 'displays delete button for each swimmer' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('fa-trash') # Delete icon
      end

      it 'shows Rescan button' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Rescan Swimmers')
      end

      it 'displays row range in pagination info' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Rows:')
        expect(response.body).to include('1..3') # 3 swimmers
      end
    end

    describe 'PATCH /data_fix/update_phase3_swimmer' do
      before(:each) do
        phase3_data = {
          'season_id' => season.id,
          'swimmers' => [
            { 'key' => 'DOE|JOHN|1985', 'last_name' => 'Doe', 'first_name' => 'John',
              'year_of_birth' => 1985, 'gender_type_code' => 'M', 'complete_name' => 'Doe John',
              'swimmer_id' => nil, 'fuzzy_matches' => [] }
          ]
        }
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: phase3_data, meta: { 'generator' => 'test' })
      end

      it 'updates swimmer attributes successfully' do
        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_index: 0,
                        swimmer: { complete_name: 'Smith John', first_name: 'John', last_name: 'Smith',
                                   year_of_birth: 1986, gender_type_code: 'M' } }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:notice]).to be_present

        # Verify data was updated
        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['swimmers'][0]['complete_name']).to eq('Smith John')
        expect(data['swimmers'][0]['last_name']).to eq('Smith')
        expect(data['swimmers'][0]['year_of_birth']).to eq(1986)
      end

      it 'updates swimmer_id when provided' do
        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_index: 0,
                        swimmer: { id: swimmer.id, complete_name: swimmer.complete_name } }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['swimmers'][0]['swimmer_id']).to eq(swimmer.id)
      end

      it 'clears downstream phase data when swimmer is updated' do
        # Add downstream data
        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        data['meeting_event'] = [{ 'some' => 'data' }]
        data['meeting_program'] = [{ 'some' => 'data' }]
        pfm.write!(data: data, meta: { 'generator' => 'test' })

        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_index: 0,
                        swimmer: { complete_name: 'Updated Name' } }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['meeting_event']).to eq([])
        expect(data['meeting_program']).to eq([])
      end

      it 'returns error for invalid swimmer_index' do
        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_index: 999,
                        swimmer: { complete_name: 'Test' } }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:warning]).to include('Invalid swimmer index')
      end

      it 'returns error for missing file_path' do
        patch update_phase3_swimmer_path,
              params: { swimmer_index: 0, swimmer: { complete_name: 'Test' } }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'updates metadata timestamp' do
        original_time = Time.now.utc - 1.hour
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: pfm.data, meta: { 'generated_at' => original_time.iso8601 })

        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_index: 0,
                        swimmer: { complete_name: 'Updated' } }

        pfm = PhaseFileManager.new(phase3_file)
        meta = pfm.meta
        updated_time = Time.parse(meta['generated_at'])
        expect(updated_time).to be > original_time
      end
    end

    describe 'POST /data_fix/add_swimmer' do
      before(:each) do
        phase3_data = {
          'season_id' => season.id,
          'swimmers' => [
            { 'key' => 'EXISTING|SWIMMER|1985', 'last_name' => 'Existing', 'first_name' => 'Swimmer',
              'year_of_birth' => 1985, 'gender_type_code' => 'M', 'complete_name' => 'Existing Swimmer',
              'swimmer_id' => nil, 'fuzzy_matches' => [] }
          ]
        }
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: phase3_data, meta: { 'generator' => 'test' })
      end

      it 'adds a new blank swimmer successfully' do
        post data_fix_add_swimmer_path, params: { file_path: source_file }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:notice]).to eq('Swimmer added')

        # Verify swimmer was added
        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['swimmers'].size).to eq(2)
        new_swimmer = data['swimmers'].last
        expect(new_swimmer['last_name']).to eq('NEW')
        expect(new_swimmer['first_name']).to eq('SWIMMER')
        expect(new_swimmer['complete_name']).to include('NEW SWIMMER')
        expect(new_swimmer['swimmer_id']).to be_nil
      end

      it 'creates unique keys for multiple new swimmers' do
        post data_fix_add_swimmer_path, params: { file_path: source_file }
        post data_fix_add_swimmer_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['swimmers'].size).to eq(3)
        expect(data['swimmers'][1]['key']).to include('NEW|SWIMMER|2')
        expect(data['swimmers'][2]['key']).to include('NEW|SWIMMER|3')
      end

      it 'sets default values for new swimmer' do
        post data_fix_add_swimmer_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        new_swimmer = data['swimmers'].last
        expect(new_swimmer['gender_type_code']).to eq('M')
        expect(new_swimmer['year_of_birth']).to be > 1900
        expect(new_swimmer['fuzzy_matches']).to eq([])
      end

      it 'returns error for missing file_path' do
        post data_fix_add_swimmer_path

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'updates metadata timestamp' do
        post data_fix_add_swimmer_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase3_file)
        meta = pfm.meta
        expect(meta['generated_at']).to be_present
      end
    end

    describe 'DELETE /data_fix/delete_swimmer' do
      before(:each) do
        phase3_data = {
          'season_id' => season.id,
          'swimmers' => [
            { 'key' => 'ALPHA|JOHN|1985', 'last_name' => 'Alpha', 'first_name' => 'John',
              'year_of_birth' => 1985, 'gender_type_code' => 'M', 'complete_name' => 'Alpha John',
              'swimmer_id' => nil, 'fuzzy_matches' => [] },
            { 'key' => 'BETA|JANE|1990', 'last_name' => 'Beta', 'first_name' => 'Jane',
              'year_of_birth' => 1990, 'gender_type_code' => 'F', 'complete_name' => 'Beta Jane',
              'swimmer_id' => swimmer.id, 'fuzzy_matches' => [] }
          ]
        }
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: phase3_data, meta: { 'generator' => 'test' })
      end

      it 'deletes swimmer successfully' do
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_index: 0 }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:notice]).to be_present

        # Verify swimmer was deleted
        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['swimmers'].size).to eq(1)
        expect(data['swimmers'][0]['complete_name']).to eq('Beta Jane')
      end

      it 'clears downstream phase data when swimmer is deleted' do
        # Add downstream data
        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        data['meeting_event'] = [{ 'some' => 'data' }]
        data['meeting_individual_result'] = [{ 'some' => 'data' }]
        pfm.write!(data: data, meta: { 'generator' => 'test' })

        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_index: 0 }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['meeting_event']).to eq([])
        expect(data['meeting_individual_result']).to eq([])
      end

      it 'returns error for invalid swimmer_index' do
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_index: 999 }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:warning]).to include('Invalid swimmer index')
      end

      it 'returns error for missing file_path' do
        delete data_fix_delete_swimmer_path, params: { swimmer_index: 0 }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'updates metadata timestamp' do
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_index: 0 }

        pfm = PhaseFileManager.new(phase3_file)
        meta = pfm.meta
        expect(meta['generated_at']).to be_present
      end
    end

    describe 'Rescan functionality' do
      it 'triggers rescan when rescan parameter is present' do
        allow(Import::Solvers::SwimmerSolver).to receive(:new).and_call_original

        get review_swimmers_path(file_path: source_file, phase3_v2: 1, rescan: 1)

        expect(Import::Solvers::SwimmerSolver).to have_received(:new)
      end

      it 'redirects without rescan parameter after rescan completes' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1, rescan: 1)

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:notice]).to be_present # Flash message in Italian: "Fase 3 ricostruita dall'origine."
      end

      it 'does not trigger rescan when phase file exists and no rescan param' do
        # Create phase3 file first
        pfm = PhaseFileManager.new(phase3_file)
        pfm.write!(data: { 'swimmers' => [] }, meta: { 'generator' => 'test' })

        allow(Import::Solvers::SwimmerSolver).to receive(:new)

        get review_swimmers_path(file_path: source_file, phase3_v2: 1)

        expect(Import::Solvers::SwimmerSolver).not_to have_received(:new)
      end
    end

    describe 'Integration with SwimmerSolver' do
      it 'uses SwimmerSolver to build phase3 file when missing' do
        FileUtils.rm_f(phase3_file)

        expect(Import::Solvers::SwimmerSolver).to receive(:new).and_call_original

        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
      end
    end

    describe 'Fallback to legacy controller' do
      it 'redirects to legacy controller when phase3_v2 is not present' do
        get review_swimmers_path(file_path: source_file)

        expect(response).to redirect_to(review_swimmers_legacy_path(file_path: source_file))
      end
    end
  end
end
