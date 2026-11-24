# frozen_string_literal: true

require 'rails_helper'

# Smoke journey 7: Season board (the Builder is stubbed, as in spec/requests/season_board_controller_spec.rb).
RSpec.describe 'Season board' do
  def build_row(overrides = {})
    defaults = {
      fin_event_id: '150091', key: 'k', date_text: '08/11', first_date: Date.new(2026, 11, 8), last_date: Date.new(2026, 11, 8),
      year: '2026', name: 'Trofeo Test', place: 'Roma', url: 'https://www.federnuoto.it/#/risultati/150091:trofeo-test', info: nil,
      calendar_id: nil, meeting_id: nil, meeting_description: nil, meeting_header_date: nil, mir_count: 0, mrr_count: 0,
      results_acquired: false, state: :link_not_crawled, state_detail: {}, next_action: nil,
      activity: { crawl: nil, extract: nil }, busy: false, flags: [], calendar: nil, disk_entry: nil
    }
    SeasonBoard::Row.new(**defaults, **overrides)
  end

  def action(kind, fin_id, **params)
    SeasonBoard::NextAction.new(kind:, params: { fin_event_id: fin_id }.merge(params))
  end

  let(:season) { GogglesDb::Season.first }
  let(:rows) do
    [
      build_row(fin_event_id: '1', name: 'To crawl', state: :link_not_crawled, next_action: action(:crawl, '1', url: 'u1'),
                url: 'https://fin.example/1'),
      build_row(fin_event_id: '2', name: 'To extract', state: :manifest_pending, next_action: action(:extract_manifest, '2', pdf_path: '/x.pdf'),
                url: 'https://fin.example/2'),
      build_row(fin_event_id: '3', name: 'To review', state: :results_ready, next_action: action(:review_results, '3', file_path: '/d/r.json'),
                url: 'https://fin.example/3')
    ]
  end
  let(:orphans) do
    [
      SeasonBoard::DbIndex::CalendarInfo.new(
        id: 321, fin_event_id: nil, meeting_id: 55, meeting_code: 'orph-code', meeting_name: 'Orphan meeting', meeting_place: nil,
        scheduled_date: Date.new(2026, 10, 1), year: 2026, month: 10, cancelled: false, results_link: nil, meeting: nil
      )
    ]
  end
  let(:result) do
    SeasonBoard::Builder::Result.new(
      season:, rows:, orphans:, unmatched_sources: [], snapshot_checked_at: Time.zone.local(2026, 11, 12, 9, 30),
      warnings: [], active_activities: []
    )
  end

  let(:builder) { instance_double(SeasonBoard::Builder, call: result) }

  before(:each) do
    allow(SeasonBoard::Builder).to receive_messages(latest_season: season, new: builder)
    sign_in_admin(prepare_admin_user)
    visit(season_board_path)
  end

  describe 'journey 7: rows, state chip filter & orphans panel' do
    it 'renders the rows, filters by a state chip and expands the orphans panel' do
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 3)

      find('a[data-state-chip="manifest_pending"]').click
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 1)
      expect(page).to have_css('#season-board-row-2')
      expect(page).to have_no_css('#season-board-row-1')

      expect(page).to have_no_css('#orphans-collapse.show')
      find_by_id('season-board-orphans').click_link(href: '#orphans-collapse')
      expect(page).to have_css('#orphans-collapse.show')
      expect(page).to have_css('#orphans-collapse', text: 'orph-code')
      expect_no_js_errors
    end
  end

  describe 'live refresh' do
    it 'reloads only the rows frame (frame-only response) on a board ping' do
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 3)
      fresh = build_row(fin_event_id: '4', name: 'Fresh row', state: :link_not_crawled, next_action: action(:crawl, '4'),
                        url: 'https://fin.example/4')
      allow(builder).to receive(:call).and_return(result.with(rows: rows + [fresh]))

      page.execute_script("document.dispatchEvent(new CustomEvent('app-notification', { detail: { dom_id: 'season-board-ping' } }))")
      expect(page).to have_css('#season-board-row-4', text: 'Fresh row')
      expect(find('turbo-frame#season-board-rows')['src']).to include('frame=1')
      expect(page).to have_css('.app-sidebar', count: 1)
      expect(page).to have_css('#season-board-table tbody tr[id^="season-board-row-"]', count: 4)
      expect_no_js_errors
    end
  end
end
