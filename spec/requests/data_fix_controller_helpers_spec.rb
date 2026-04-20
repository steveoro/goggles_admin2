# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController, type: :controller do
  include AdminSignInHelpers

  describe '#detect_layout_type' do
    subject { controller.send(:detect_layout_type, file_path) }

    context 'with LT2 format file (Molinella sample)' do
      let(:file_path) { 'spec/fixtures/results/season-182_Molinella_sample.json' }

      it 'returns 2' do
        expect(subject).to eq(2)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(2)
      end
    end

    context 'with large LT4 file and layoutType near EOF' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:file_path) { File.join(temp_dir, 'meeting-lt4.json') }

      before(:each) do
        payload = {
          'meetingName' => 'Large LT4 Meeting',
          'padding' => ('A' * 80_000),
          'layoutType' => 4
        }
        File.write(file_path, JSON.pretty_generate(payload))
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'returns 4' do
        expect(subject).to eq(4)
      end
    end

    context 'with LT2 format file (Saronno sample)' do
      let(:file_path) { 'spec/fixtures/results/season-192_Saronno_sample.json' }

      it 'returns 2' do
        expect(subject).to eq(2)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(2)
      end
    end

    context 'with LT4 format file' do
      let(:file_path) { 'spec/fixtures/import/sample-200RA-l4.json' }

      it 'returns 4' do
        expect(subject).to eq(4)
      end

      it 'correctly identifies layoutType field in file' do
        data = JSON.parse(File.read(file_path))
        expect(data['layoutType']).to eq(4)
      end
    end

    context 'with missing layoutType field' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:file_path) { File.join(temp_dir, 'invalid.json') }

      before(:each) do
        # Create file without layoutType field
        File.write(file_path, JSON.generate({ 'name' => 'Test Meeting' }))
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'defaults to 2' do
        expect(subject).to eq(2)
      end
    end

    context 'with unparseable file' do
      let(:temp_dir) { Dir.mktmpdir }
      let(:file_path) { File.join(temp_dir, 'corrupt.json') }

      before(:each) do
        File.write(file_path, 'not valid json{')
      end

      after(:each) do
        FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
      end

      it 'defaults to 2 (handles error gracefully)' do
        expect(subject).to eq(2)
      end
    end
  end

  describe '#resolve_working_source_path' do
    subject(:resolved_path) { controller.send(:resolve_working_source_path, file_path) }

    let(:temp_dir) { Dir.mktmpdir }
    let(:source_path) { File.join(temp_dir, 'meeting.json') }
    let(:lt4_path) { File.join(temp_dir, 'meeting-lt4.json') }

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    context 'with LT4 source file' do
      let(:file_path) { source_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 4, 'name' => 'LT4 meeting' }))
      end

      it 'returns the same path' do
        expect(resolved_path).to eq(source_path)
      end
    end

    context 'with LT2 source file and missing LT4 working copy' do
      let(:file_path) { source_path }

      before(:each) do
        lt2_payload = {
          'layoutType' => 2,
          'name' => 'LT2 meeting',
          'sections' => [
            {
              'title' => '50 SL M25',
              'rows' => [
                { 'name' => 'Rossi Mario', 'year' => 1985, 'team' => 'Team A', 'timing' => '00:31.00' }
              ]
            }
          ]
        }
        File.write(source_path, JSON.pretty_generate(lt2_payload))
      end

      it 'materializes and returns the sibling -lt4 path' do
        expect(resolved_path).to eq(lt4_path)
        expect(File.exist?(lt4_path)).to be true

        data = JSON.parse(File.read(lt4_path))
        expect(data['layoutType']).to eq(4)
        expect(data['events']).to be_an(Array)
        expect(data['events']).not_to be_empty
        expect(data['swimmers']).to be_present
      end
    end

    context 'with LT2 source file and existing LT4 working copy' do
      let(:file_path) { source_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 2, 'sections' => [] }))
        File.write(lt4_path, JSON.pretty_generate({ 'layoutType' => 4, 'name' => 'Existing working copy' }))
      end

      it 'reuses existing LT4 copy' do
        expect(resolved_path).to eq(lt4_path)
        data = JSON.parse(File.read(lt4_path))
        expect(data['name']).to eq('Existing working copy')
      end
    end

    context 'with phase file that points to LT2 source' do
      let(:phase3_path) { File.join(temp_dir, 'meeting-phase3.json') }
      let(:file_path) { phase3_path }

      before(:each) do
        File.write(source_path, JSON.pretty_generate({ 'layoutType' => 2, 'sections' => [] }))
        PhaseFileManager.new(phase3_path).write!(
          data: { 'swimmers' => [] },
          meta: { 'source_path' => source_path }
        )
      end

      it 'resolves canonical LT4 working source path' do
        expect(resolved_path).to eq(lt4_path)
      end
    end
  end

  describe '#build_badge_season_check_report' do
    let(:season) { instance_double(GogglesDb::Season) }
    let(:checker) do
      instance_double(
        Merge::BadgeSeasonChecker,
        run: nil,
        sure_badge_merges: sure_badges,
        possible_badge_merges: possible_badges,
        multi_badges: {},
        possible_team_merges: [],
        relay_badges: [],
        relay_only_badges: []
      )
    end
    let(:sure_badges) { {} }
    let(:possible_badges) { {} }

    before(:each) do
      allow(Merge::BadgeSeasonChecker).to receive(:new).with(season: season).and_return(checker)
      allow(controller).to receive(:serialize_badge_merges).and_return([])
    end

    it 'returns error status when sure merges are present' do
      allow(checker).to receive(:sure_badge_merges).and_return({ 101 => [instance_double(GogglesDb::Badge)] })

      result = controller.send(:build_badge_season_check_report, season)
      expect(result[:status]).to eq('error')
      expect(result[:sure_badge_merges_count]).to eq(1)
    end

    it 'returns warning status when only possible merges are present' do
      allow(checker).to receive(:possible_badge_merges).and_return({ 202 => [instance_double(GogglesDb::Badge)] })

      result = controller.send(:build_badge_season_check_report, season)
      expect(result[:status]).to eq('warning')
      expect(result[:possible_badge_merges_count]).to eq(1)
    end

    it 'returns ok status when no merges are present' do
      result = controller.send(:build_badge_season_check_report, season)
      expect(result[:status]).to eq('ok')
      expect(result[:sure_badge_merges_count]).to eq(0)
      expect(result[:possible_badge_merges_count]).to eq(0)
    end
  end

  describe '#build_duplicate_results_check_report' do
    let(:season) { instance_double(GogglesDb::Season) }
    let(:meeting) { instance_double(GogglesDb::Meeting, id: 77, description: 'Test Meeting') }
    let(:cleaner) { instance_double(Merge::DuplicateResultCleaner) }

    before(:each) do
      allow(Merge::DuplicateResultCleaner).to receive(:new).with(season: season, autofix: false).and_return(cleaner)
      allow(cleaner).to receive(:meetings_to_process).and_return([meeting])
      allow(cleaner).to receive(:find_duplicate_mirs).with(meeting.id).and_return([])
      allow(cleaner).to receive(:find_duplicate_laps).with(meeting.id).and_return([])
      allow(cleaner).to receive(:find_duplicate_mrss).with(meeting.id).and_return([])
      allow(cleaner).to receive(:find_duplicate_relay_laps).with(meeting.id).and_return([])
      allow(cleaner).to receive(:find_duplicate_mrrs).with(meeting.id).and_return([])
      allow(controller).to receive(:serialize_duplicate_mirs).and_return([])
    end

    it 'returns ok status when all duplicate counts are zero' do
      result = controller.send(:build_duplicate_results_check_report, season)
      expect(result[:status]).to eq('ok')
      expect(result[:totals]).to eq({ mirs: 0, laps: 0, mrss: 0, relay_laps: 0, mrrs: 0 })
    end

    it 'returns error status when duplicates are found' do
      allow(cleaner).to receive(:find_duplicate_mirs).with(meeting.id).and_return([instance_double(GogglesDb::MeetingIndividualResult)])

      result = controller.send(:build_duplicate_results_check_report, season)
      expect(result[:status]).to eq('error')
      expect(result[:totals][:mirs]).to eq(1)
      expect(result[:meetings_with_findings_count]).to eq(1)
    end
  end

  describe 'GET #commit_phase6_report post-commit checks rendering' do
    render_views

    let(:base_report_data) do
      {
        file_path: '/tmp/source.json',
        log_path: '/tmp/source.log',
        sql_filename: '0001-source.sql',
        commit_success: true,
        error_message: nil,
        stats: { errors: [] },
        season_id: 212,
        done_dir: '/tmp/done',
        first_error_step_label: nil
      }
    end

    before(:each) do
      allow(controller).to receive_messages(authenticate_user!: true, check_jwt_session: true, user_signed_in?: false)
    end

    it 'shows all-green message when both checks are ok' do
      session[:commit_report] = base_report_data
      check_payload = {
        season_id: 212,
        overall_status: 'ok',
        badge_season_check: {
          status: 'ok',
          sure_badge_merges_count: 0,
          possible_badge_merges_count: 0,
          multi_badges_count: 0,
          possible_team_merges_count: 0,
          relay_badges_count: 0,
          sure_badge_merges: [],
          possible_badge_merges: []
        },
        duplicate_results_check: {
          status: 'ok',
          totals: { mirs: 0, laps: 0, mrss: 0, relay_laps: 0, mrrs: 0 },
          meetings_with_findings_count: 0,
          meetings_with_findings: []
        }
      }
      allow(controller).to receive(:build_post_commit_checks_report).and_return(check_payload)

      get :commit_phase6_report

      expect(response).to be_successful
      expect(response.body).to include('Post-Commit Integrity Checks')
      expect(response.body).to include('ALL GREEN')
      expect(response.body).to include('All green.')
    end

    it 'shows warning and error details when findings exist' do
      session[:commit_report] = base_report_data
      check_payload = sample_check_payload_with_findings
      allow(controller).to receive(:build_post_commit_checks_report).and_return(check_payload)

      get :commit_phase6_report

      expect(response).to be_successful
      expect(response.body).to include('Sure Badge Merge Candidates (Errors)')
      expect(response.body).to include('Possible Badge Merge Candidates (Warnings)')
      expect(response.body).to include('Duplicate Result Findings (Errors)')
    end

    it 'does not run post-commit checks when commit failed' do
      session[:commit_report] = base_report_data.merge(commit_success: false)
      allow(controller).to receive(:build_post_commit_checks_report).and_call_original

      get :commit_phase6_report

      expect(controller).not_to have_received(:build_post_commit_checks_report)

      expect(response).to be_successful
      expect(response.body).not_to include('Post-Commit Integrity Checks')
    end
  end

  private

  def sample_check_payload_with_findings
    {
      season_id: 212,
      overall_status: 'error',
      badge_season_check: sample_badge_season_check,
      duplicate_results_check: sample_duplicate_results_check
    }
  end

  def sample_badge_season_check
    {
      status: 'warning',
      sure_badge_merges_count: 1,
      possible_badge_merges_count: 1,
      multi_badges_count: 2,
      possible_team_merges_count: 1,
      relay_badges_count: 0,
      sure_badge_merges: sample_sure_badge_merges,
      possible_badge_merges: sample_possible_badge_merges
    }
  end

  def sample_duplicate_results_check
    {
      status: 'error',
      totals: { mirs: 1, laps: 0, mrss: 0, relay_laps: 0, mrrs: 0 },
      meetings_with_findings_count: 1,
      meetings_with_findings: [sample_meeting_with_findings]
    }
  end

  def sample_sure_badge_merges
    [
      {
        swimmer_id: 1,
        swimmer_name: 'Rossi Mario',
        badges: [{ id: 10, team_id: 20, team_name: 'Team A', category_code: 'M35' }]
      }
    ]
  end

  def sample_possible_badge_merges
    [
      {
        swimmer_id: 2,
        swimmer_name: 'Bianchi Luca',
        badges: [{ id: 11, team_id: 21, team_name: 'Team B', category_code: 'M40' }]
      }
    ]
  end

  def sample_meeting_with_findings
    {
      meeting_id: 5,
      meeting_description: 'Meeting X',
      counts: { mirs: 1, laps: 0, mrss: 0, relay_laps: 0, mrrs: 0 },
      duplicate_mirs: []
    }
  end
end
