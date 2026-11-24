# frozen_string_literal: true

require 'rails_helper'

# Phase 6 commit and the SQL Outbox (structure-only source, the smallest commit): the script is registered inside
# the local transaction; archiving failures get their own state and a retry.
RSpec.describe DataFix::CommitsController, :data_fix_commit do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:temp_dir) { Dir.mktmpdir }
  let(:new_dir) { File.join(temp_dir, 'results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:done_dir) { File.join(temp_dir, 'results.done', '262') }
  let(:source_file) { File.join(new_dir, 'outbox_meeting-lt4.json') }
  let(:phase1_file) { source_file.sub('.json', '-phase1.json') }
  let(:phase5_file) { source_file.sub('.json', '-phase5.json') }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "specoutbox#{rand(100_000)}" }

  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Outbox Spec Meeting', 'code' => meeting_code,
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

  before(:each) do
    File.write(source_file, JSON.pretty_generate('_meta' => { 'meeting_only' => true }, 'layoutType' => 4,
                                                 'meetingName' => 'Outbox Spec Meeting', 'seasonId' => season.id, 'events' => [],
                                                 'meetingURL' => 'https://www.federnuoto.it/x.html#/risultati/150321:outbox.html'))
    PhaseFileManager.new(phase1_file).write!(data: phase1_data, meta: { 'generator' => 'spec' })
    PhaseFileManager.new(phase5_file).write!(
      data: { 'name' => 'phase5', 'source_file' => File.basename(source_file), 'programs' => [] }, meta: { 'generator' => 'spec' }
    )
    write_sql_file(temp_dir, 'results.sent/misc/0476-merge_teams-1-2.sql')
    sign_in_admin(admin_user)
  end

  after(:each) { FileUtils.rm_rf(temp_dir) }

  it 'registers the commit script (pending, kind commit, same data root) and archives the files' do
    commit!(source_file)

    report = last_report
    expect(report).to have_attributes(status: 'committed', sql_filename: '0477-outbox_meeting-lt4.sql')
    script = Ops::SqlScript.find(report.sql_script_id)
    expect(script).to have_attributes(kind: 'commit', state: 'pending', folder: '262', rel_path: 'results.new/262/0477-outbox_meeting-lt4.sql')
    expect(script.origin).to include('producer' => 'data_fix.commit', 'source_base' => 'outbox_meeting', 'fin_event_id' => '150321',
                                     'meeting_id' => GogglesDb::Meeting.find_by(code: meeting_code).id)
    sql = File.read(File.join(new_dir, '0477-outbox_meeting-lt4.sql'))
    expect(sql).to start_with('-- Outbox Spec Meeting').and end_with("\r\n--\r\n\nCOMMIT;")
    expect(File).to exist(File.join(done_dir, File.basename(source_file)))
    expect(Ops::Event.last).to have_attributes(kind: 'datafix.committed', link_path: outbox_path(focus: '0477-outbox_meeting-lt4.sql'))
  end

  it 'rolls the local commit back and reports failed when the script cannot be written' do
    allow(Outbox::Writer).to receive(:write!).and_raise(Errno::ENOSPC, 'disk full')

    expect { commit!(source_file) }.not_to change(Ops::SqlScript, :count)

    expect(last_report).to have_attributes(status: 'failed', sql_filename: nil)
    expect(last_report.error_message).to include('disk full')
    expect(GogglesDb::Meeting.find_by(code: meeting_code)).to be_nil
    expect(File).to exist(source_file) # (nothing archived)
    expect(Ops::Event.last).to have_attributes(kind: 'datafix.commit_failed')
  end

  it 'deletes a script already written when the local transaction rolls back afterwards' do
    allow_any_instance_of(Import::Committers::Main).to receive(:commit_all).and_wrap_original do |original, **kwargs| # rubocop:disable RSpec/AnyInstance
      original.call(before_commit: lambda { |sql|
        kwargs[:before_commit].call(sql)
        raise ActiveRecord::StatementInvalid, 'deadlock'
      })
    end

    commit!(source_file)

    expect(last_report.status).to eq('failed')
    expect(Ops::SqlScript.count).to eq(0)
    expect(Dir.glob(File.join(new_dir, '*.sql'))).to be_empty
    expect(GogglesDb::Meeting.find_by(code: meeting_code)).to be_nil
  end

  context 'when archiving fails after the commit' do
    before(:each) do
      allow(DataFix::CommitArchiver).to receive(:finalize).and_call_original
      allow(DataFix::CommitArchiver).to receive(:finalize).once.and_raise(Errno::EACCES, 'results.done')
    end

    it "reports 'committed, archiving failed' with the script registered" do
      commit!(source_file)

      report = last_report
      expect(report.status).to eq('committed_archive_failed')
      expect(report.archive_error).to include('results.done')
      expect(Ops::SqlScript.find(report.sql_script_id)).to be_pending
      expect(GogglesDb::Meeting.find_by(code: meeting_code)).to be_present
      expect(Ops::Event.last).to have_attributes(kind: 'datafix.archive_failed', level: 'warning')
    end

    it 'shows the state, the script link and the retry action on the report' do
      commit!(source_file)
      follow_redirect!

      page = response.parsed_body
      expect(page.at_css('#commit-archive-failed')).to be_present
      expect(page.at_css("a[href='#{outbox_path(focus: '0477-outbox_meeting-lt4.sql')}']")).to be_present
      expect(page.at_css("form[action='#{data_fix_retry_archive_path}']")).to be_present
    end

    it 'completes the archiving on retry (idempotent)' do
      commit!(source_file)
      allow(DataFix::CommitArchiver).to receive(:finalize).and_call_original

      post data_fix_retry_archive_path, params: { file_path: source_file, sql_filename: '0477-outbox_meeting-lt4.sql' }
      expect(response).to redirect_to(data_fix_commit_report_path(last_report))
      expect(last_report.status).to eq('committed')
      expect(File).to exist(File.join(done_dir, File.basename(source_file)))
      expect(Ops::Event.last).to have_attributes(kind: 'datafix.archived')

      post data_fix_retry_archive_path, params: { file_path: source_file }
      expect(last_report.reload.status).to eq('committed')
    end
  end

  it 'refuses a retry for a path outside results.new' do
    post data_fix_retry_archive_path, params: { file_path: '/etc/passwd' }
    expect(response).to redirect_to(sources_results_path)
  end
end
