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

      it 'rejects invalid scheduled_date format' do
        patch update_phase1_session_path, params: {
          file_path: source_file,
          session_index: 0,
          scheduled_date: '15-12-2024' # Wrong format
        }
        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:warning]).to be_present
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
