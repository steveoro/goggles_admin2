# frozen_string_literal: true

require 'rails_helper'

# 0.10.104 journey: the redundant file of a linked meeting, flagged on the Season board, is moved away from the Sources
# clean-up page (dry run first, then the operator's apply); the board flag is gone. Everything lives in a temporary
# 'crawler/data' root (SeasonBoard::DiskIndex.default_data_dir, hence Sources.data_root, is stubbed to it); the board
# is built for real from the watcher snapshot and a calendar of the test DB linked to a meeting.
RSpec.describe 'Sources clean-up' do
  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir('system-cleanup-')).realpath.join('crawler', 'data') }
  let(:season) { SeasonBoard::Builder.latest_season }
  let(:fin_id) { '199901' }
  let(:fin_url) { "#{Sources::CrawlKinds::FIN_RESULTS_BASE_URL}#{fin_id}:trofeo-pulizia.html" }
  let(:source_name) { '2026-11-08-Trofeo_Pulizia.json' }
  let(:source_path) { data_root.join('results.new', season.id.to_s, source_name) }

  before(:each) do
    FileUtils.mkdir_p(source_path.dirname)
    File.write(source_path, { 'layoutType' => 2, 'name' => 'Trofeo Pulizia', 'meetingURL' => fin_url, 'sections' => [] }.to_json)
    File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, source_path)
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_root)
    allow(Outbox).to receive(:data_root).and_return(data_root)
    allow(SystemStatus::CrawlerProbe).to receive(:status_path).and_return(data_root.join('no-crawler-status.json'))
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
    meeting = FactoryBot.create(:meeting, season:, results_acquired: false)
    FactoryBot.create(:calendar, season:, meeting:, results_code: fin_id)
    FedernuotoWatch::StateStore.new.update do
      { 'last_checked' => Time.current.iso8601,
        'rows' => [{ 'year' => '2026', 'date' => '08/11', 'name' => 'Trofeo Pulizia', 'place' => 'Roma', 'url' => fin_url, 'info' => '' }] }
    end
    sign_in_through_form(admin_user)
  end

  after(:each) do
    FileUtils.rm_rf(data_root.dirname.dirname)
    FileUtils.rm_f([SeasonBoard::ActivityLog.default_path, FedernuotoWatch::StateStore.default_path])
  end

  it 'lists the redundant file, moves it to the backup folder on confirmation, and the board flag goes away' do
    visit(season_board_path(row: fin_id))
    expect(page).to have_css("#season-board-row-#{fin_id} [data-flag='redundant_result_free_source']")

    visit(sources_results_path(season_id: season.id))
    click_link(I18n.t('sources.cleanup.link', count: 1))
    expect(page).to have_css('#sources-cleanup-intro', text: I18n.t('sources.cleanup.intro.nothing_deleted'))
    expect(page).to have_css("#sources-cleanup-table tr[data-cleanup-file='#{source_name}']",
                             text: "results.backup/#{season.id}/cleanup-<timestamp>/#{source_name}")

    accept_confirm { click_button('btn-sources-cleanup-apply') }
    expect(page).to have_css('#sources-cleanup-empty')
    expect(page).to have_css('.toast, .alert', text: I18n.t('sources.cleanup.flash.done', moved: 1, skipped: 0, folder: '').split(':').first)
    expect(Dir.glob(data_root.join('results.backup', season.id.to_s, 'cleanup-*', source_name).to_s).size).to eq(1)

    visit(season_board_path(row: fin_id))
    expect(page).to have_css("#season-board-row-#{fin_id}")
    expect(page).to have_no_css("#season-board-row-#{fin_id} [data-flag='redundant_result_free_source']")
    expect_no_js_errors
  end
end
