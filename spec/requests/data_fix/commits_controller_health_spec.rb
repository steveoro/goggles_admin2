# frozen_string_literal: true

require 'rails_helper'

# (phase 06) A Phase 6 commit queues the data health checks of the season (structure-only source, the smallest commit).
RSpec.describe DataFix::CommitsController, :data_fix_commit do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:temp_dir) { Dir.mktmpdir }
  let(:new_dir) { File.join(temp_dir, 'results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_file) { File.join(new_dir, 'health_hook_meeting-lt4.json') }
  let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
  let(:phase4_file) { source_file.sub('.json', '-phase4.json') }
  let(:phase5_file) { source_file.sub('.json', '-phase5.json') }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "spechealth#{rand(100_000)}" }

  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Health Hook Spec Meeting', 'code' => meeting_code,
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
                                                 'meetingName' => 'Health Hook Spec Meeting', 'seasonId' => season.id, 'events' => []))
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

  it 'queues every health group of the season (trigger post_commit) after a successful commit' do
    write_phase_files
    expect { commit!(source_file) }
      .to have_enqueued_job(Health::SeasonRunJob).on_queue('maintenance').exactly(Ops::HealthRun::GROUPS.size).times
    expect(last_report.status).to eq('committed')
    expect(Ops::HealthRun.for_season(season.id).pending.pluck(:trigger).uniq).to eq(['post_commit'])
    # (phase 09) the 'results' and 'badges' runs are stored on the report, which shows them in a lazy frame
    runs = Ops::HealthRun.where(id: last_report.health_run_ids.values)
    expect(runs.pluck(:group_key)).to match_array(%w[results badges])
  end

  it 'queues nothing when the commit fails' do
    write_phase_files(phase4_events: [{ 'key' => 'ZZZ99', 'distance' => 9999, 'stroke' => 'XX', 'session_order' => 1 }])
    expect { commit!(source_file) }.not_to have_enqueued_job(Health::SeasonRunJob)
    expect(last_report.status).to eq('failed')
  end

  it 'never fails the commit when the health runs cannot be queued' do
    write_phase_files
    allow(Health::SeasonRunJob).to receive(:enqueue_season).and_raise(StandardError, 'queue down')
    commit!(source_file)
    expect(last_report.status).to eq('committed')
    expect(response).to redirect_to(data_fix_commit_report_path(last_report))
  end
end
