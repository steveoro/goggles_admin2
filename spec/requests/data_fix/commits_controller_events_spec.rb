# frozen_string_literal: true

require 'rails_helper'

# Ops event log rows written by the Phase 6 commit (structure-only source, the smallest commit).
RSpec.describe DataFix::CommitsController do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:temp_dir) { Dir.mktmpdir }
  let(:new_dir) { File.join(temp_dir, 'results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_file) { File.join(new_dir, 'ops_event_meeting-lt4.json') }
  let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
  let(:phase4_file) { source_file.sub('.json', '-phase4.json') }
  let(:phase5_file) { source_file.sub('.json', '-phase5.json') }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "specops#{rand(100_000)}" }

  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Ops Event Spec Meeting', 'code' => meeting_code,
      'header_year' => '2026/2027', 'header_date' => '2026-10-24', 'edition' => 1,
      'edition_type_id' => GogglesDb::EditionType::ORDINAL_ID, 'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID,
      'dateYear1' => 2026, 'dateMonth1' => 10, 'dateDay1' => 24,
      'meeting_session' => [
        {
          'id' => nil, 'description' => 'Session 1, 2026-10-24', 'session_order' => 1, 'scheduled_date' => '2026-10-24',
          'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
          'swimming_pool' => {
            'id' => swimming_pool.id, 'name' => swimming_pool.name, 'nick_name' => swimming_pool.nick_name,
            'address' => swimming_pool.address, 'pool_type_id' => swimming_pool.pool_type_id,
            'lanes_number' => swimming_pool.lanes_number, 'city_id' => swimming_pool.city_id
          }
        }
      ]
    }
  end

  def write_phase_files(phase4_events: nil)
    File.write(source_file, JSON.pretty_generate('_meta' => { 'meeting_only' => true }, 'layoutType' => 4,
                                                 'meetingName' => 'Ops Event Spec Meeting', 'seasonId' => season.id, 'events' => []))
    PhaseFileManager.new(phase1_file).write!(data: phase1_data, meta: { 'generator' => 'spec' })
    if phase4_events
      PhaseFileManager.new(phase4_file).write!(data: { 'sessions' => [{ 'session_order' => 1, 'events' => phase4_events }] },
                                               meta: { 'generator' => 'spec' })
    end
    PhaseFileManager.new(phase5_file).write!(
      data: { 'name' => 'phase5', 'source_file' => File.basename(source_file), 'programs' => [] }, meta: { 'generator' => 'spec' }
    )
  end

  before(:each) { sign_in_admin(admin_user) }
  after(:each) { FileUtils.rm_rf(temp_dir) }

  describe 'POST /data_fix/commit_phase6' do
    it 'records one datafix.committed event on success' do
      write_phase_files
      expect { post commit_phase6_path(file_path: source_file) }.to change(Ops::Event, :count).by(1)

      expect(session[:commit_report][:commit_success]).to be true
      event = Ops::Event.last
      expect(event).to have_attributes(kind: 'datafix.committed', level: 'success', actor: 'operator', season_id: season.id,
                                       subject_type: 'source', subject_key: source_file)
      expect(event.data['sql_filename']).to eq(session[:commit_report][:sql_filename])
      expect(event.data['sql_filename']).to end_with('-ops_event_meeting-lt4.sql')
      expect(event.data).not_to have_key('first_error')
    end

    it 'records one datafix.commit_failed event (with the first error) on failure' do
      write_phase_files(phase4_events: [{ 'key' => 'ZZZ99', 'distance' => 9999, 'stroke' => 'XX', 'session_order' => 1 }])
      expect { post commit_phase6_path(file_path: source_file) }.to change(Ops::Event, :count).by(1)

      expect(session[:commit_report][:commit_success]).to be false
      event = Ops::Event.last
      expect(event).to have_attributes(kind: 'datafix.commit_failed', level: 'error', actor: 'operator', subject_key: source_file)
      expect(event.season_id).to eq(262) # (no archive on failure: taken from the source folder)
      expect(event.data['first_error']).to start_with('Phase 6 commit failed')
    end

    it 'commits all the same when the event write fails' do
      write_phase_files
      allow(Ops::Event).to receive(:create!).and_raise(ActiveRecord::StatementTimeout, 'database is locked')

      post commit_phase6_path(file_path: source_file)

      expect(response).to redirect_to(data_fix_commit_phase6_report_path)
      expect(session[:commit_report][:commit_success]).to be true
      expect(GogglesDb::Meeting.find_by(code: meeting_code)).to be_present
    end

    it 'commits all the same when the ops DB is not available' do
      write_phase_files
      allow(Ops::Database).to receive(:state).and_return(:missing)

      expect { post commit_phase6_path(file_path: source_file) }.not_to change(Ops::Event, :count)
      expect(response).to redirect_to(data_fix_commit_phase6_report_path)
      expect(session[:commit_report][:commit_success]).to be true
    end
  end
end
