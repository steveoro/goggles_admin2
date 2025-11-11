# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 1 (Sessions) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(temp_dir, 'test_source.json') }
    let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
    let(:season) { FactoryBot.create(:season) }

    before(:each) do
      sign_in_admin(admin_user)
      # Create a minimal source file
      File.write(source_file, JSON.generate({ 'layoutType' => 2, 'name' => 'Test Meeting' }))
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    describe 'GET /data_fix/review_sessions with phase_v2=1' do
      before(:each) do
        # Create phase1 file with test data
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'poolLength' => '25',
          'meeting_session' => []
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'loads the phase1 view successfully' do
        get review_sessions_path(file_path: source_file, phase_v2: 1)
        expect(response).to be_successful
        expect(response.body).to include('Test Meeting')
      end

      it 'displays empty sessions message when no sessions exist' do
        get review_sessions_path(file_path: source_file, phase_v2: 1)
        expect(response.body).to include('No sessions yet')
      end
    end

    describe 'PATCH /data_fix/update_phase1_meeting' do
      before(:each) do
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Original Meeting',
          'poolLength' => '25'
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'updates meeting description' do
        patch update_phase1_meeting_path, params: {
          file_path: source_file,
          description: 'Updated Meeting Name',
          season_id: season.id
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))

        # Verify file was updated
        pfm = PhaseFileManager.new(phase1_file)
        expect(pfm.data['name']).to eq('Updated Meeting Name')
      end

      it 'updates all meeting fields' do
        edition_type = GogglesDb::EditionType.first
        timing_type = GogglesDb::TimingType.first

        patch update_phase1_meeting_path, params: {
          file_path: source_file,
          description: 'Full Meeting',
          code: 'TEST2024',
          season_id: season.id,
          header_year: '2024/2025',
          header_date: '2024-12-15',
          edition: 10,
          edition_type_id: edition_type.id,
          timing_type_id: timing_type.id,
          cancelled: '0',
          confirmed: '1',
          max_individual_events: 5,
          max_individual_events_per_session: 3,
          poolLength: '50'
        }

        pfm = PhaseFileManager.new(phase1_file)
        data = pfm.data
        expect(data['name']).to eq('Full Meeting')
        expect(data['code']).to eq('TEST2024')
        expect(data['header_year']).to eq('2024/2025')
        expect(data['header_date']).to eq('2024-12-15')
        expect(data['edition']).to eq(10)
        expect(data['edition_type_id']).to eq(edition_type.id)
        expect(data['timing_type_id']).to eq(timing_type.id)
        expect(data['cancelled']).to be false
        expect(data['confirmed']).to be true
        expect(data['max_individual_events']).to eq(5)
        expect(data['max_individual_events_per_session']).to eq(3)
        expect(data['poolLength']).to eq('50')
      end

      it 'rejects invalid pool length' do
        patch update_phase1_meeting_path, params: {
          file_path: source_file,
          poolLength: '75',
          season_id: season.id
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:warning]).to be_present
      end
    end

    describe 'PATCH /data_fix/update_phase1_session' do
      let(:city) { FactoryBot.create(:city, name: 'Test City') }
      let(:pool_type) { GogglesDb::PoolType.first }
      let(:day_part_type) { GogglesDb::DayPartType.first }

      before(:each) do
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'meeting_session' => [
            {
              'id' => 1,
              'description' => 'Session 1',
              'session_order' => 1,
              'scheduled_date' => '2024-12-15',
              'swimming_pool' => {},
              'city' => {}
            }
          ]
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'updates session basic fields' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 0,
          description: 'Updated Session',
          session_order: 2,
          scheduled_date: '2024-12-20',
          day_part_type_id: day_part_type.id
        }

        pfm = PhaseFileManager.new(phase1_file)
        sess = pfm.data['meeting_session'][0]
        expect(sess['description']).to eq('Updated Session')
        expect(sess['session_order']).to eq(2)
        expect(sess['scheduled_date']).to eq('2024-12-20')
        expect(sess['day_part_type_id']).to eq(day_part_type.id)
      end

      it 'updates nested pool data' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 0,
          pool: {
            name: 'Test Pool',
            nick_name: 'test-pool',
            address: '123 Pool St',
            pool_type_id: pool_type.id,
            lanes_number: 8,
            maps_uri: 'https://maps.google.com/test',
            plus_code: 'ABC123',
            latitude: '45.123',
            longitude: '12.456'
          }
        }

        pfm = PhaseFileManager.new(phase1_file)
        pool = pfm.data['meeting_session'][0]['swimming_pool']
        expect(pool['name']).to eq('Test Pool')
        expect(pool['nick_name']).to eq('test-pool')
        expect(pool['address']).to eq('123 Pool St')
        expect(pool['pool_type_id']).to eq(pool_type.id)
        expect(pool['lanes_number']).to eq(8)
        expect(pool['maps_uri']).to eq('https://maps.google.com/test')
        expect(pool['plus_code']).to eq('ABC123')
        expect(pool['latitude']).to eq('45.123')
        expect(pool['longitude']).to eq('12.456')
      end

      it 'updates nested city data' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 0,
          city: {
            name: 'Test City',
            area: 'Test Province',
            zip: '12345',
            country: 'Italy',
            country_code: 'IT',
            latitude: '45.123',
            longitude: '12.456'
          }
        }

        pfm = PhaseFileManager.new(phase1_file)
        city_data = pfm.data['meeting_session'][0]['swimming_pool']['city']
        expect(city_data['name']).to eq('Test City')
        expect(city_data['area']).to eq('Test Province')
        expect(city_data['zip']).to eq('12345')
        expect(city_data['country']).to eq('Italy')
        expect(city_data['country_code']).to eq('IT')
        expect(city_data['latitude']).to eq('45.123')
        expect(city_data['longitude']).to eq('12.456')
      end

      it 'ignores invalid scheduled_date format and logs warning' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 0,
          scheduled_date: '15-12-2024' # Wrong format
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))

        # Verify the invalid date was not saved
        pfm = PhaseFileManager.new(phase1_file)
        sess = pfm.data['meeting_session'][0]
        expect(sess['scheduled_date']).to eq('2024-12-15') # Original value unchanged
      end

      it 'returns error for invalid session_index' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 99, # Out of range
          description: 'Invalid'
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:warning]).to be_present
      end
    end

    describe 'POST /data_fix/add_session' do
      before(:each) do
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'meeting_session' => [
            {
              'id' => 1,
              'description' => 'Session 1',
              'session_order' => 1,
              'scheduled_date' => '2024-12-15'
            }
          ]
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'creates a new blank session' do
        post data_fix_add_session_path, params: { file_path: source_file }
        expect(response).to have_http_status(:redirect)
        expect(response.location).to include('/data_fix/review_sessions')
        expect(response.location).to include("file_path=#{CGI.escape(source_file)}")
        expect(response.location).to include('phase_v2=1')

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions.size).to eq(2)

        new_session = sessions[1]
        expect(new_session['id']).to be_nil
        expect(new_session['description']).to eq('Session 2')
        expect(new_session['session_order']).to eq(2)
        expect(new_session['scheduled_date']).to be_nil
        expect(new_session['swimming_pool']).to be_a(Hash)
        expect(new_session['swimming_pool']['city']).to be_a(Hash)
      end

      it 'increments session_order correctly' do
        # Add second session
        post data_fix_add_session_path, params: { file_path: source_file }
        # Add third session
        post data_fix_add_session_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions.size).to eq(3)
        expect(sessions[0]['session_order']).to eq(1)
        expect(sessions[1]['session_order']).to eq(2)
        expect(sessions[2]['session_order']).to eq(3)
      end

      it 'updates metadata timestamp' do
        original_time = Time.parse('2024-01-01T00:00:00Z')
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: pfm.data, meta: { 'generated_at' => original_time.iso8601 })

        post data_fix_add_session_path, params: { file_path: source_file }

        pfm = PhaseFileManager.new(phase1_file)
        new_time = Time.zone.parse(pfm.meta['generated_at'])
        expect(new_time).to be > original_time
      end

      it 'requires file_path parameter' do
        post data_fix_add_session_path, params: { file_path: '' }
        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'DELETE /data_fix/delete_session' do
      before(:each) do
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'meeting_session' => [
            {
              'id' => 1,
              'description' => 'Session 1',
              'session_order' => 1,
              'scheduled_date' => '2024-12-15'
            },
            {
              'id' => 2,
              'description' => 'Session 2',
              'session_order' => 2,
              'scheduled_date' => '2024-12-16'
            },
            {
              'id' => 3,
              'description' => 'Session 3',
              'session_order' => 3,
              'scheduled_date' => '2024-12-17'
            }
          ],
          'meeting_event' => [{ 'id' => 1 }],
          'meeting_program' => [{ 'id' => 1 }],
          'meeting_individual_result' => [{ 'id' => 1 }]
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'removes session at specified index' do
        delete data_fix_delete_session_path, params: {
          file_path: source_file,
          session_index: 1 # Remove Session 2
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions.size).to eq(2)
        expect(sessions[0]['description']).to eq('Session 1')
        expect(sessions[1]['description']).to eq('Session 3')
      end

      it 'clears downstream phase data' do
        delete data_fix_delete_session_path, params: {
          file_path: source_file,
          session_index: 0
        }

        pfm = PhaseFileManager.new(phase1_file)
        data = pfm.data
        expect(data['meeting_event']).to eq([])
        expect(data['meeting_program']).to eq([])
        expect(data['meeting_individual_result']).to eq([])
        expect(data['lap']).to eq([])
        expect(data['relay_lap']).to eq([])
        expect(data['meeting_relay_swimmer']).to eq([])
      end

      it 'rejects negative session_index' do
        delete data_fix_delete_session_path, params: {
          file_path: source_file,
          session_index: -1
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:warning]).to be_present

        # Verify no sessions were deleted
        pfm = PhaseFileManager.new(phase1_file)
        expect(pfm.data['meeting_session'].size).to eq(3)
      end

      it 'rejects out-of-range session_index' do
        delete data_fix_delete_session_path, params: {
          file_path: source_file,
          session_index: 99
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:warning]).to be_present

        # Verify no sessions were deleted
        pfm = PhaseFileManager.new(phase1_file)
        expect(pfm.data['meeting_session'].size).to eq(3)
      end

      it 'requires file_path parameter' do
        delete data_fix_delete_session_path, params: {
          file_path: '',
          session_index: 0
        }
        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'POST /data_fix/rescan_phase1_sessions' do
      let!(:meeting) do
        FactoryBot.create(:meeting,
                          season: season,
                          description: 'Existing Meeting',
                          code: 'TEST2024')
      end
      let!(:pool_type) { GogglesDb::PoolType.first }
      let!(:day_part_type) { GogglesDb::DayPartType.first }
      let!(:city) { FactoryBot.create(:city, name: 'Rescan City') }
      let!(:pool) do
        FactoryBot.create(:swimming_pool,
                          name: 'Rescan Pool',
                          nick_name: 'rescan-pool',
                          city: city,
                          pool_type: pool_type,
                          lanes_number: 8)
      end
      let!(:session1) do
        FactoryBot.create(:meeting_session,
                          meeting: meeting,
                          session_order: 1,
                          description: 'Morning Session',
                          scheduled_date: Date.parse('2024-12-15'),
                          swimming_pool: pool,
                          day_part_type: day_part_type)
      end
      let!(:session2) do
        FactoryBot.create(:meeting_session,
                          meeting: meeting,
                          session_order: 2,
                          description: 'Afternoon Session',
                          scheduled_date: Date.parse('2024-12-15'),
                          swimming_pool: pool,
                          day_part_type: day_part_type)
      end

      before(:each) do
        phase1_data = {
          'id' => meeting.id,
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'meeting_session' => [
            { 'id' => 999, 'description' => 'Old Session' }
          ]
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })
      end

      it 'rebuilds sessions from existing meeting' do
        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: meeting.id
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions.size).to eq(2)

        # Verify first session
        sess1 = sessions[0]
        expect(sess1['id']).to eq(session1.id)
        expect(sess1['description']).to eq('Morning Session')
        expect(sess1['session_order']).to eq(1)
        expect(sess1['scheduled_date']).to eq('2024-12-15')
        expect(sess1['day_part_type_id']).to eq(day_part_type.id)

        # Verify second session
        sess2 = sessions[1]
        expect(sess2['id']).to eq(session2.id)
        expect(sess2['description']).to eq('Afternoon Session')
        expect(sess2['session_order']).to eq(2)
      end

      it 'includes nested swimming pool data' do
        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: meeting.id
        }

        pfm = PhaseFileManager.new(phase1_file)
        pool_data = pfm.data['meeting_session'][0]['swimming_pool']
        expect(pool_data['id']).to eq(pool.id)
        expect(pool_data['name']).to eq('Rescan Pool')
        expect(pool_data['nick_name']).to eq('rescan-pool')
        expect(pool_data['pool_type_id']).to eq(pool_type.id)
        expect(pool_data['lanes_number']).to eq(8)
        expect(pool_data['city_id']).to eq(city.id)
      end

      it 'includes nested city data' do
        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: meeting.id
        }

        pfm = PhaseFileManager.new(phase1_file)
        city_data = pfm.data['meeting_session'][0]['swimming_pool']['city']
        expect(city_data['id']).to eq(city.id)
        expect(city_data['name']).to eq('Rescan City')
      end

      it 'clears sessions when meeting_id is blank' do
        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: ''
        }

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions).to eq([])
      end

      it 'clears sessions when meeting_id is nil and no meeting in data' do
        # Create phase1 file WITHOUT meeting id
        phase1_data = {
          'season_id' => season.id,
          'name' => 'Test Meeting',
          'meeting_session' => [
            { 'id' => 999, 'description' => 'Old Session' }
          ]
        }
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: phase1_data, meta: { 'generator' => 'test' })

        post rescan_phase1_sessions_path, params: {
          file_path: source_file
          # No meeting_id parameter
        }

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions).to eq([])
      end

      it 'clears sessions when meeting not found' do
        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: 99_999 # Non-existent ID
        }

        pfm = PhaseFileManager.new(phase1_file)
        sessions = pfm.data['meeting_session']
        expect(sessions).to eq([])
      end

      it 'clears downstream phase data' do
        # Add some downstream data first
        pfm = PhaseFileManager.new(phase1_file)
        data = pfm.data
        data['meeting_event'] = [{ 'id' => 1 }]
        data['meeting_program'] = [{ 'id' => 1 }]
        data['meeting_individual_result'] = [{ 'id' => 1 }]
        pfm.write!(data: data, meta: pfm.meta)

        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: meeting.id
        }

        pfm = PhaseFileManager.new(phase1_file)
        expect(pfm.data['meeting_event']).to eq([])
        expect(pfm.data['meeting_program']).to eq([])
        expect(pfm.data['meeting_individual_result']).to eq([])
        expect(pfm.data['lap']).to eq([])
        expect(pfm.data['relay_lap']).to eq([])
        expect(pfm.data['meeting_relay_swimmer']).to eq([])
      end

      it 'updates metadata timestamp' do
        original_time = Time.parse('2024-01-01T00:00:00Z')
        pfm = PhaseFileManager.new(phase1_file)
        pfm.write!(data: pfm.data, meta: { 'generated_at' => original_time.iso8601 })

        post rescan_phase1_sessions_path, params: {
          file_path: source_file,
          meeting_id: meeting.id
        }

        pfm = PhaseFileManager.new(phase1_file)
        new_time = Time.zone.parse(pfm.meta['generated_at'])
        expect(new_time).to be > original_time
      end

      it 'requires file_path parameter' do
        post rescan_phase1_sessions_path, params: {
          file_path: '',
          meeting_id: meeting.id
        }
        expect(response).to redirect_to(pull_index_path)
        expect(flash[:warning]).to be_present
      end
    end

    describe 'Phase1Solver integration with fuzzy matches' do
      let!(:existing_meeting) do
        FactoryBot.create(:meeting,
                          season: season,
                          description: 'Test Regional Championship 2024')
      end

      it 'includes fuzzy matches in generated phase1 file' do
        solver = Import::Solvers::Phase1Solver.new(season: season)
        solver.build!(source_path: source_file, lt_format: 2,
                      data_hash: { 'layoutType' => 2, 'name' => 'Regional Championship' })

        pfm = PhaseFileManager.new(phase1_file)
        matches = pfm.data['meeting_fuzzy_matches']
        expect(matches).to be_an(Array)
        expect(matches.size).to be > 0
        expect(matches.first['id']).to eq(existing_meeting.id)
        expect(matches.first['description']).to eq(existing_meeting.description)
      end
    end
  end
end
