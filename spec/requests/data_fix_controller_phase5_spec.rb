# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 5 (Results) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file_a) { File.join(temp_dir, 'source_a.json') }
    let(:source_file_b) { File.join(temp_dir, 'source_b.json') }
    let(:phase5_file_a) { source_file_a.sub('.json', '-phase5.json') }

    before(:each) do
      sign_in_admin(admin_user)
      File.write(source_file_a, JSON.pretty_generate({ 'layoutType' => 4, 'events' => [] }))
      File.write(source_file_b, JSON.pretty_generate({ 'layoutType' => 4, 'events' => [] }))

      File.write(
        phase5_file_a,
        JSON.pretty_generate(
          {
            'name' => 'phase5',
            'source_file' => File.basename(source_file_a),
            'programs' => [
              {
                'session_order' => 1,
                'event_key' => '100SL',
                'event_code' => '100SL',
                'category_code' => 'M25',
                'gender_code' => 'M',
                'relay' => false,
                'result_count' => 1
              },
              {
                'session_order' => 1,
                'event_key' => '4X50SL',
                'event_code' => '4X50SL',
                'category_code' => 'M120',
                'gender_code' => 'X',
                'relay' => true,
                'result_count' => 1
              }
            ]
          }
        )
      )
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    describe 'GET /data_fix/review_results with phase5_v2=1' do
      before(:each) do
        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-100SL-M25-M/AAA|SOURCE|1980',
          phase_file_path: source_file_a,
          swimmer_key: 'AAA|SOURCE|1980',
          rank: 1
        )
        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-100SL-M25-M/LEAK|SWIMMER|1977',
          phase_file_path: source_file_b,
          swimmer_key: 'LEAK|SWIMMER|1977',
          rank: 99
        )

        GogglesDb::DataImportMeetingRelayResult.create!(
          import_key: '1-4X50SL-M120-X/TEAM_A/02:00.00',
          phase_file_path: source_file_a,
          rank: 5
        )
        GogglesDb::DataImportMeetingRelayResult.create!(
          import_key: '1-4X50SL-M120-X/TEAM_LEAK/02:22.22',
          phase_file_path: source_file_b,
          rank: 77
        )
      end

      it 'scopes per-program rendering to current source path only' do
        get review_results_path(file_path: source_file_a, phase5_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include('AAA|SOURCE|1980')
        expect(response.body).not_to include('LEAK|SWIMMER|1977')
        expect(response.body).to include('1 relay results')
        expect(response.body).not_to include('2 relay results')
      end
    end

    describe 'DELETE /data_fix/purge' do
      before(:each) do
        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: 'purge-mir',
          phase_file_path: source_file_a,
          swimmer_key: 'PURGE|MIR|1980'
        )
        GogglesDb::DataImportLap.create!(
          import_key: 'purge-lap',
          parent_import_key: 'purge-mir',
          phase_file_path: source_file_a,
          length_in_meters: 50
        )
        GogglesDb::DataImportMeetingRelayResult.create!(
          import_key: 'purge-mrr',
          phase_file_path: source_file_a
        )
        GogglesDb::DataImportMeetingRelaySwimmer.create!(
          import_key: 'purge-mrs',
          parent_import_key: 'purge-mrr',
          phase_file_path: source_file_a,
          relay_order: 1
        )
        GogglesDb::DataImportRelayLap.create!(
          import_key: 'purge-relay-lap',
          parent_import_key: 'purge-mrr',
          phase_file_path: source_file_a,
          length_in_meters: 50
        )
      end

      it 'clears all temp tables and redirects with a notice' do
        delete data_fix_purge_path

        expect(response).to redirect_to(home_index_path)
        expect(flash[:notice]).to include('Clean slate completed')
        expect(GogglesDb::DataImportMeetingIndividualResult.count).to eq(0)
        expect(GogglesDb::DataImportLap.count).to eq(0)
        expect(GogglesDb::DataImportMeetingRelayResult.count).to eq(0)
        expect(GogglesDb::DataImportMeetingRelaySwimmer.count).to eq(0)
        expect(GogglesDb::DataImportRelayLap.count).to eq(0)
      end
    end
  end
end
