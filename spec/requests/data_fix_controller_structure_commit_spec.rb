# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'structure-only commits (result-free sources)' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    # Sources live under a results.new dir so the post-commit move to results.done works
    let(:new_dir) { File.join(temp_dir, 'results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:source_file) { File.join(new_dir, 'manifest_meeting-lt4.json') }
    let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
    let(:phase4_file) { source_file.sub('.json', '-phase4.json') }
    let(:phase5_file) { source_file.sub('.json', '-phase5.json') }

    let(:season) { FactoryBot.create(:season) }
    let(:city) { FactoryBot.create(:city) }
    let(:swimming_pool) { FactoryBot.create(:swimming_pool, city: city) }

    let(:valid_phase1_data) do
      {
        'season_id' => season.id,
        'name' => 'Manifest Spec Meeting',
        'code' => "speccmit#{rand(100_000)}",
        'header_year' => '2026/2027',
        'header_date' => '2026-10-24',
        'edition' => 1,
        'edition_type_id' => GogglesDb::EditionType::ORDINAL_ID,
        'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID,
        'dateYear1' => 2026,
        'dateMonth1' => 10,
        'dateDay1' => 24,
        'meeting_session' => [
          {
            'id' => nil,
            'description' => 'Session 1, 2026-10-24',
            'session_order' => 1,
            'scheduled_date' => '2026-10-24',
            'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
            'swimming_pool' => {
              'id' => swimming_pool.id,
              'name' => swimming_pool.name,
              'nick_name' => swimming_pool.nick_name,
              'address' => swimming_pool.address,
              'pool_type_id' => swimming_pool.pool_type_id,
              'lanes_number' => swimming_pool.lanes_number,
              'city_id' => city.id,
              'city' => {
                'id' => city.id,
                'name' => city.name,
                'area' => city.area,
                'zip' => city.zip,
                'country' => city.country,
                'country_code' => city.country_code
              }
            }
          }
        ]
      }
    end

    def write_source(results: [], meeting_only: true)
      meta = meeting_only ? { 'meeting_only' => true } : {}
      File.write(
        source_file,
        JSON.pretty_generate(
          '_meta' => meta,
          'layoutType' => 4,
          'meetingName' => 'Manifest Spec Meeting',
          'seasonId' => season.id,
          'events' => results
        )
      )
    end

    def write_phase1(data)
      PhaseFileManager.new(phase1_file).write!(data: data, meta: { 'generator' => 'spec' })
    end

    def write_phase4(sessions)
      PhaseFileManager.new(phase4_file).write!(data: { 'sessions' => sessions }, meta: { 'generator' => 'spec' })
    end

    def write_phase5(programs = [])
      PhaseFileManager.new(phase5_file).write!(
        data: { 'name' => 'phase5', 'source_file' => File.basename(source_file), 'programs' => programs },
        meta: { 'generator' => 'spec' }
      )
    end

    before(:each) do
      sign_in_admin(admin_user)
      write_source
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    describe 'GET /data_fix/review_results (result-free source)' do
      it 'renders the structure-only commit button enabled when the structure is valid' do
        write_phase1(valid_phase1_data)
        write_phase5

        get review_results_path(file_path: source_file, phase5_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include(I18n.t('data_import.data_fix.btn_commit_structure'))
        expect(response.body).to include(I18n.t('data_import.data_fix.structure_only_title'))
        expect(response.body).not_to include(I18n.t('data_import.data_fix.structure_invalid_title'))
        form = response.parsed_body.css("form[action='#{commit_phase6_path(file_path: source_file)}']").first
        expect(form.css('button[type=submit]').first.attr('disabled')).to be_nil
      end

      it 'disables the commit button and lists errors when the structure is invalid' do
        write_phase1(valid_phase1_data.merge('code' => nil, 'header_year' => nil))
        write_phase5

        get review_results_path(file_path: source_file, phase5_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include(I18n.t('data_import.data_fix.structure_invalid_title'))
        expect(response.body).to include('Code')
        form = response.parsed_body.css("form[action='#{commit_phase6_path(file_path: source_file)}']").first
        expect(form.css('button[type=submit]').first.attr('disabled')).to be_present
      end
    end

    describe 'POST /data_fix/commit_phase6' do
      it 'commits meeting + session with manifest flag for a valid result-free source' do
        write_phase1(valid_phase1_data)
        write_phase5

        post commit_phase6_path(file_path: source_file)

        expect(response).to redirect_to(data_fix_commit_phase6_report_path)
        meeting = GogglesDb::Meeting.find_by(code: valid_phase1_data['code'])
        expect(meeting).to be_present
        expect(meeting.manifest).to be true
        expect(meeting.meeting_sessions.count).to eq(1)
        expect(session[:commit_report][:commit_success]).to be true
      end

      it 'commits optional resolvable events alongside the structure' do
        event_type = GogglesDb::EventType.find_by(code: '1500SL') || GogglesDb::EventType.individual.first
        write_phase1(valid_phase1_data)
        write_phase4(
          [
            {
              'session_order' => 1,
              'events' => [
                { 'key' => event_type.code, 'event_type_id' => event_type.id, 'session_order' => 1 }
              ]
            }
          ]
        )
        write_phase5

        post commit_phase6_path(file_path: source_file)

        meeting = GogglesDb::Meeting.find_by(code: valid_phase1_data['code'])
        expect(meeting).to be_present
        expect(meeting.meeting_sessions.first.meeting_events.count).to eq(1)
      end

      it 'rejects the commit when a present event cannot be resolved' do
        write_phase1(valid_phase1_data)
        write_phase4(
          [
            {
              'session_order' => 1,
              'events' => [
                { 'key' => 'ZZZ99', 'distance' => 9999, 'stroke' => 'XX', 'session_order' => 1 }
              ]
            }
          ]
        )
        write_phase5

        post commit_phase6_path(file_path: source_file)

        expect(response).to redirect_to(data_fix_commit_phase6_report_path)
        expect(session[:commit_report][:commit_success]).to be false
        expect(GogglesDb::Meeting.find_by(code: valid_phase1_data['code'])).to be_nil
      end

      it 'redirects to Step 1 and creates nothing when the structure is invalid' do
        write_phase1(valid_phase1_data.merge('code' => nil, 'header_year' => nil))
        write_phase5

        post commit_phase6_path(file_path: source_file)

        expect(response).to redirect_to(review_sessions_path(file_path: source_file, phase_v2: 1))
        expect(flash[:error]).to include('Invalid meeting structure')
        expect(GogglesDb::Meeting.find_by(description: 'Manifest Spec Meeting')).to be_nil
      end

      it 'keeps the existing rescan guard for result-bearing sources with no staged rows' do
        write_source(results: [{ 'code' => '1500SL', 'results' => [{ 'rank' => 1 }] }], meeting_only: false)
        write_phase1(valid_phase1_data)
        PhaseFileManager.new(source_file.sub('.json', '-phase2.json'))
                        .write!(data: { 'teams' => [] }, meta: {})
        PhaseFileManager.new(source_file.sub('.json', '-phase3.json'))
                        .write!(data: { 'swimmers' => [] }, meta: {})
        write_phase4([{ 'session_order' => 1, 'events' => [] }])
        write_phase5([{ 'session_order' => 1, 'event_code' => '1500SL', 'category_code' => 'M25', 'gender_code' => 'M' }])

        post commit_phase6_path(file_path: source_file)

        expect(response).to redirect_to(review_results_path(file_path: source_file, phase5_v2: 1, rescan: 1))
      end
    end

    describe 'GET /data_fix/review_sessions (Step 1 validation cues)' do
      it 'highlights missing required meeting fields with is-invalid without blocking the page' do
        write_phase1(valid_phase1_data.merge('code' => nil, 'header_year' => nil))

        get review_sessions_path(file_path: source_file, phase_v2: 1)

        expect(response).to be_successful
        expect(response.body).to include('is-invalid')
        # Missing auto-computed code should remind the operator to save the form
        # (assert on a quote-free fragment: the key embeds escaped quotes)
        expect(response.body).to include(I18n.t('data_import.data_fix.code_autocomputed_hint').split('"').first)
      end

      it 'does not flag fields when all required meeting data is present' do
        write_phase1(valid_phase1_data)

        get review_sessions_path(file_path: source_file, phase_v2: 1)

        expect(response).to be_successful
        expect(response.body).not_to include('is-invalid')
      end
    end
  end
end
