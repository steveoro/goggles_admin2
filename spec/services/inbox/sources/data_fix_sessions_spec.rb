# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require_relative '../summary_fixtures'
require_relative '../../season_board/disk_fixtures'

RSpec.describe Inbox::Sources::DataFixSessions do
  include InboxSummaryFixtures
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir('inbox-sessions') }
  let(:now) { Time.current }
  let(:gone) { 'crawler/data/results.new/9995/gone-lt4.json' }
  let(:items) { described_class.new.items(inbox_context(now:, data_dir:)).index_by(&:kind) }

  before(:each) { GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'inbox-src-gone', phase_file_path: gone, rank: 1) }

  after(:each) do
    GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: gone).delete_all
    FileUtils.remove_entry(data_dir)
  end

  def write_with_mtime(name, mtime)
    path = write_file('results.new', name, '{}')
    File.utime(mtime.to_time, mtime.to_time, path)
  end

  it 'asks to resume a session idle for 3 days or more (not a fresher one) at its highest step' do
    write_file('results.new', 'old-lt4.json', '{}')
    write_with_mtime('old-lt4-phase2.json', 4.days.ago)
    write_file('results.new', 'fresh-lt4.json', '{}')
    write_with_mtime('fresh-lt4-phase1.json', 2.days.ago)

    idle = items[:idle_session]
    expect(idle.key).to eq("session:#{path_for('results.new', 'old-lt4.json')}")
    expect(idle.band).to eq(:notice)
    expect(idle.action.path).to start_with('/data_fix/review_teams?')
    expect(described_class.new.items(inbox_context(now:, data_dir:)).count { |item| item.kind == :idle_session }).to eq(1)
  end

  it 'resumes at the step of the stored verdicts, with the review filter and the stage (phase 10)' do
    write_file('results.new', 'old-lt4.json', '{}')
    write_with_mtime('old-lt4-phase3.json', 4.days.ago)
    FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'old', stage: 'needs_review', review_phase: 2)

    idle = items[:idle_session]
    expect(idle.action.path).to start_with('/data_fix/review_teams?').and include('filter_state=review')
    expect(idle.detail).to include(I18n.t('pipeline_automation.stages.needs_review'))
  end

  it 'offers to purge the staging rows whose source is gone (DELETE with a confirm)' do
    purge = items[:orphan_staging]
    expect(purge.key).to eq("session:#{gone}:purge")
    expect(purge.action).to have_attributes(http_method: :delete, path: '/data_fix/sessions/purge', params: { source_path: gone })
    expect(purge.action.confirm).to be_present
  end
end
