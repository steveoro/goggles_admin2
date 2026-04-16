# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 5 (Results) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file_a) { File.join(temp_dir, 'source_a.json') }
    let(:source_file_b) { File.join(temp_dir, 'source_b.json') }
    let(:phase1_file_a) { source_file_a.sub('.json', '-phase1.json') }
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
                'event_key' => '200RA',
                'event_code' => '200RA',
                'category_code' => 'M30',
                'gender_code' => nil,
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
      def rewrite_phase5_programs!(programs)
        File.write(
          phase5_file_a,
          JSON.pretty_generate(
            {
              'name' => 'phase5',
              'source_file' => File.basename(source_file_a),
              'programs' => programs
            }
          )
        )
      end

      def ensure_phase1_season!
        season = GogglesDb::Season.first ||
                 FactoryBot.create(
                   :season,
                   season_type_id: GogglesDb::SeasonType::MAS_FIN_ID,
                   edition_type_id: GogglesDb::EditionType::YEARLY_ID,
                   timing_type_id: GogglesDb::TimingType::AUTOMATIC_ID
                 )
        File.write(phase1_file_a, JSON.pretty_generate({ 'data' => { 'season_id' => season.id } }))
        season
      end

      def seed_team_swimmer_context!(season:, with_badge:)
        team = FactoryBot.create(:team)
        team_affiliation = FactoryBot.create(:team_affiliation, team: team, season: season)
        swimmer = FactoryBot.create(:swimmer)
        return { team: team, team_affiliation: team_affiliation, swimmer: swimmer, badge: nil } unless with_badge

        category_type = season.category_types.where(relay: false).first || FactoryBot.create(:category_type, season: season)
        badge = FactoryBot.create(
          :badge,
          swimmer: swimmer,
          team: team,
          team_affiliation: team_affiliation,
          season: season,
          category_type: category_type
        )

        { team: team, team_affiliation: team_affiliation, swimmer: swimmer, badge: badge }
      end

      def expect_no_phase5_issues!
        get review_results_path(file_path: source_file_a, phase5_v2: 1)
        expect(response).to be_successful
        expect(response.body).to include('All results are valid!')
        expect(response.body).to include('No unresolved required links detected.')
      end

      before(:each) do
        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-100SL-M25-M/AAA|SOURCE|1980',
          phase_file_path: source_file_a,
          swimmer_key: 'AAA|SOURCE|1980',
          rank: 1
        )
        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-200RA-M30-/UNK|NO_GENDER|1981',
          meeting_program_key: '1-200RA-M30-',
          phase_file_path: source_file_a,
          swimmer_key: 'UNK|NO_GENDER|1981',
          rank: 2
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
        expect(response.body).to include('UNK|NO_GENDER|1981')
        expect(response.body).not_to include('LEAK|SWIMMER|1977')
        expect(response.body).to include('1 relay results')
        expect(response.body).not_to include('2 relay results')
      end

      it 'flags unresolved program gender as an issue' do
        get review_results_path(file_path: source_file_a, phase5_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include('program(s) with issues detected')
        expect(response.body).to include('missing program gender')
        expect(response.body).to include('unresolved required links')
      end

      it 'does not flag nil meeting_program_id as issue when links are coherent and key has gender' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all
        GogglesDb::DataImportMeetingRelayResult.delete_all
        rewrite_phase5_programs!([
                                   {
                                     'session_order' => 1,
                                     'event_key' => '100SL',
                                     'event_code' => '100SL',
                                     'category_code' => 'M25',
                                     'gender_code' => 'M',
                                     'relay' => false,
                                     'result_count' => 1
                                   }
                                 ])
        season = ensure_phase1_season!
        seeded = seed_team_swimmer_context!(season: season, with_badge: true)

        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-100SL-M25-M/COHERENT|SWIMMER|1980',
          meeting_program_key: '1-100SL-M25-M',
          phase_file_path: source_file_a,
          swimmer_id: seeded[:swimmer].id,
          swimmer_key: 'COHERENT|SWIMMER|1980',
          team_id: seeded[:team].id,
          badge_id: seeded[:badge].id,
          rank: 1
        )
        expect_no_phase5_issues!
      end

      it 'does not flag missing badge_id when swimmer/team links are solvable' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all
        GogglesDb::DataImportMeetingRelayResult.delete_all
        rewrite_phase5_programs!([
                                   {
                                     'session_order' => 1,
                                     'event_key' => '100SL',
                                     'event_code' => '100SL',
                                     'category_code' => 'M25',
                                     'gender_code' => 'M',
                                     'relay' => false,
                                     'result_count' => 1
                                   }
                                 ])
        season = ensure_phase1_season!
        seeded = seed_team_swimmer_context!(season: season, with_badge: false)

        GogglesDb::DataImportMeetingIndividualResult.create!(
          import_key: '1-100SL-M25-M/NEW|BADGE|1984',
          meeting_program_key: '1-100SL-M25-M',
          phase_file_path: source_file_a,
          swimmer_id: seeded[:swimmer].id,
          swimmer_key: 'NEW|BADGE|1984',
          team_id: seeded[:team].id,
          team_key: seeded[:team].editable_name,
          badge_id: nil,
          rank: 1
        )
        expect_no_phase5_issues!
      end

      it 'does not flag missing team_affiliation_id for relay when team link is solvable' do
        GogglesDb::DataImportMeetingIndividualResult.delete_all
        GogglesDb::DataImportMeetingRelayResult.delete_all
        GogglesDb::DataImportMeetingRelaySwimmer.delete_all
        rewrite_phase5_programs!([
                                   {
                                     'session_order' => 1,
                                     'event_key' => '4X50SL',
                                     'event_code' => '4X50SL',
                                     'category_code' => 'M120',
                                     'gender_code' => 'X',
                                     'relay' => true,
                                     'result_count' => 1
                                   }
                                 ])
        season = ensure_phase1_season!
        seeded = seed_team_swimmer_context!(season: season, with_badge: false)

        GogglesDb::DataImportMeetingRelayResult.create!(
          import_key: '1-4X50SL-M120-X/TEAM_SOLVABLE/02:01.11',
          meeting_program_key: '1-4X50SL-M120-X',
          phase_file_path: source_file_a,
          team_id: seeded[:team].id,
          team_key: seeded[:team].editable_name,
          team_affiliation_id: nil,
          rank: 1
        )
        GogglesDb::DataImportMeetingRelaySwimmer.create!(
          import_key: '1-4X50SL-M120-X/TEAM_SOLVABLE/02:01.11-swimmer1',
          parent_import_key: '1-4X50SL-M120-X/TEAM_SOLVABLE/02:01.11',
          phase_file_path: source_file_a,
          swimmer_id: seeded[:swimmer].id,
          swimmer_key: 'SOLVABLE|RELAY|1982',
          badge_id: nil,
          relay_order: 1
        )
        expect_no_phase5_issues!
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
