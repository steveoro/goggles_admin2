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
              'swimmer_id' => swimmer.id, 'fuzzy_matches' => [{ 'id' => swimmer.id,
                                                                'display_label' => "#{swimmer.complete_name} (1990, ID: #{swimmer.id}, match: 95%)" }] },
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

        get review_swimmers_path(file_path: source_file, phase3_v2: 1, swimmers_per_page: 100, swimmers_page: 1)
        expect(response).to be_successful
        expect(response.body).to include('Swimmer1 Test')
        expect(response.body).to include('Swimmer100 Test') # Last on page 1
        expect(response.body).not_to include('Swimmer101 Test') # First on page 2
      end

      it 'filters swimmers by name' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1, q: 'Beta')
        expect(response.body).to include('Beta Jane')
        expect(response.body).not_to include('Alpha John')
        expect(response.body).not_to include('Gamma Bob')
      end

      it 'displays phase metadata' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Phase 3 Metadata') # Metadata header in collapsed card
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

      it 'shows phase navigation' do
        get review_swimmers_path(file_path: source_file, phase3_v2: 1)
        expect(response.body).to include('Step 3') # Phase header
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
              params: { file_path: source_file, swimmer_key: 'DOE|JOHN|1985',
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
              params: { file_path: source_file, swimmer_key: 'DOE|JOHN|1985',
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
              params: { file_path: source_file, swimmer_key: 'DOE|JOHN|1985',
                        swimmer: { complete_name: 'Updated Name' } }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['meeting_event']).to eq([])
        expect(data['meeting_program']).to eq([])
      end

      it 'returns error for invalid swimmer key' do
        patch update_phase3_swimmer_path,
              params: { file_path: source_file, swimmer_key: 'UNKNOWN|KEY|999',
                        swimmer: { complete_name: 'Test' } }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:warning]).to include('Swimmer not found')
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
              params: { file_path: source_file, swimmer_key: 'DOE|JOHN|1985',
                        swimmer: { complete_name: 'Updated' } }

        pfm = PhaseFileManager.new(phase3_file)
        meta = pfm.meta
        updated_time = Time.zone.parse(meta['generated_at'])
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
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_key: 'ALPHA|JOHN|1985' }

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

        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_key: 'ALPHA|JOHN|1985' }

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        expect(data['meeting_event']).to eq([])
        expect(data['meeting_individual_result']).to eq([])
      end

      it 'returns error for invalid swimmer key' do
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_key: 'UNKNOWN|KEY|999' }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:warning]).to include('Swimmer not found')
      end

      it 'returns error for missing file_path' do
        delete data_fix_delete_swimmer_path, params: { swimmer_index: 0 }

        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end

      it 'updates metadata timestamp' do
        delete data_fix_delete_swimmer_path, params: { file_path: source_file, swimmer_key: 'ALPHA|JOHN|1985' }

        pfm = PhaseFileManager.new(phase3_file)
        meta = pfm.meta
        expect(meta['generated_at']).to be_present
      end
    end

    describe 'Relay enrichment workflow' do
      let(:relay_payload) do
        {
          'layoutType' => 4,
          'sections' => [
            {
              'title' => '4x50 Mixed Medley',
              'fin_sigla_categoria' => 'M200',
              'rows' => [
                {
                  'relay' => true,
                  'team' => 'Sharks Masters',
                  'swimmer1' => 'Alpha John',
                  'laps' => []
                }
              ]
            }
          ]
        }
      end

      let(:incomplete_swimmer) do
        {
          'key' => 'ALPHA|JOHN|0',
          'last_name' => 'Alpha',
          'first_name' => 'John',
          'complete_name' => 'Alpha John',
          'year_of_birth' => 0,
          'gender_type_code' => nil,
          'swimmer_id' => nil,
          'fuzzy_matches' => []
        }
      end

      let(:aux_phase3_file) { File.join(temp_dir, 'auxiliary-phase3.json') }

      it 'renders relay enrichment panel when incomplete relay swimmers are detected' do
        File.write(source_file, JSON.pretty_generate(relay_payload))

        PhaseFileManager.new(phase3_file).write!(
          data: { 'swimmers' => [incomplete_swimmer], 'badges' => [] },
          meta: { 'generator' => 'test' }
        )

        get review_swimmers_path(file_path: source_file, phase3_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include('Phase 3: Missing Swimmer Data')
        expect(response.body).to include('Alpha John')
        # Without auxiliary files, shows warning instead of button
        expect(response.body).to include(I18n.t('data_import.relay_enrichment.no_auxiliary_files'))
      end

      it 'does not render relay enrichment panel when no relay issues are found' do
        complete_payload = JSON.parse(relay_payload.to_json)
        complete_payload['sections'][0]['rows'][0]['year_of_birth1'] = 1985
        complete_payload['sections'][0]['rows'][0]['gender_type1'] = 'M'
        File.write(source_file, JSON.pretty_generate(complete_payload))

        complete_swimmer = incomplete_swimmer.merge(
          'key' => 'ALPHA|JOHN|1985',
          'year_of_birth' => 1985,
          'gender_type_code' => 'M',
          'swimmer_id' => swimmer.id
        )

        PhaseFileManager.new(phase3_file).write!(
          data: { 'swimmers' => [complete_swimmer], 'badges' => [] },
          meta: { 'generator' => 'test' }
        )

        get review_swimmers_path(file_path: source_file, phase3_v2: 1)

        expect(response.body).not_to include('Phase 3: Missing Swimmer Data')
      end

      it 'merges swimmers and badges from auxiliary phase3 files' do # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
        File.write(source_file, JSON.pretty_generate(relay_payload))

        main_data = {
          'swimmers' => [incomplete_swimmer],
          'badges' => [],
          'meeting_event' => [{ 'existing' => 'value' }],
          'meeting_program' => [{ 'existing' => 'value' }],
          'meeting_individual_result' => [{ 'existing' => 'value' }],
          'meeting_relay_result' => [{ 'existing' => 'value' }]
        }
        PhaseFileManager.new(phase3_file).write!(data: main_data, meta: { 'generator' => 'test' })

        aux_data = {
          'swimmers' => [
            incomplete_swimmer.merge(
              'year_of_birth' => 1980,
              'gender_type_code' => 'M',
              'swimmer_id' => swimmer.id,
              'fuzzy_matches' => [{ 'id' => swimmer.id, 'label' => swimmer.complete_name }]
            )
          ],
          'badges' => [
            { 'swimmer_key' => 'ALPHA|JOHN|0', 'team_key' => 'Sharks Masters', 'season_id' => season.id }
          ]
        }
        PhaseFileManager.new(aux_phase3_file).write!(data: aux_data, meta: { 'generator' => 'auxiliary' })

        post merge_phase3_swimmers_path,
             params: { file_path: source_file, auxiliary_paths: [aux_phase3_file] }

        expect(response).to redirect_to(review_swimmers_path(file_path: source_file, phase3_v2: 1))
        expect(flash[:notice]).to eq(
          I18n.t(
            'data_import.relay_enrichment.merge_success',
            swimmers_added: 0,
            swimmers_updated: 1,
            badges_added: 1
          )
        )
        expect(flash[:warning]).to be_nil

        pfm = PhaseFileManager.new(phase3_file)
        data = pfm.data
        meta = pfm.meta

        File.write('/tmp/relay_merge_data.json', JSON.pretty_generate(data))
        File.write('/tmp/relay_merge_meta.json', JSON.pretty_generate(meta))

        merged_swimmer = data['swimmers'].find { |s| s['key'] == 'ALPHA|JOHN|0' }
        expect(merged_swimmer['year_of_birth']).to eq(1980)
        expect(merged_swimmer['gender_type_code']).to eq('M')
        expect(merged_swimmer['swimmer_id']).to eq(swimmer.id)

        %w[meeting_event meeting_program meeting_individual_result meeting_relay_result].each do |key|
          expect(data[key]).to eq([])
        end

        expect(meta['auxiliary_phase3_paths']).to include(File.basename(aux_phase3_file))
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
