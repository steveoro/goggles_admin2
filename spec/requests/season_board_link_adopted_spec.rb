# frozen_string_literal: true

require 'rails_helper'

# 0.10.102: "Link to meeting" on a row whose link is adopted from the FIN 'Eventi' calendar always asks first.
RSpec.describe 'Season board link of an adopted row' do
  include AdminSignInHelpers

  let(:season) { GogglesDb::Season.first }
  let(:adopted_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150112:x.html' }
  let(:link) do
    SeasonBoard::CalendarIndex::Link.new(url: adopted_url, fin_event_id: '150112', name: '9° Sardinia in Water',
                                         calendar_date: Date.new(2026, 11, 25), file_name: '20261125-262-2-FIN-calendar.csv')
  end
  let(:row) do
    SeasonBoard::Row.new(
      fin_event_id: '150112', key: 'k', date_text: '22/11', first_date: Date.new(2026, 11, 22), last_date: Date.new(2026, 11, 22),
      year: '2026', name: '9° Sardinia in Water', place: 'Cagliari', url: adopted_url, info: nil, calendar_id: nil, meeting_id: nil,
      meeting_description: nil, meeting_header_date: nil, mir_count: 0, mrr_count: 0, results_acquired: false, state: :archived_unlinked,
      state_detail: {}, next_action: SeasonBoard::NextAction.new(kind: :link, params: { fin_event_id: '150112', bases: ['b'] }),
      activity: { crawl: nil, extract: nil }, busy: false, flags: [:link_adopted], calendar: nil, disk_entry: nil, adopted_link: link
    )
  end
  let(:result) do
    SeasonBoard::Builder::Result.new(season:, rows: [row], orphans: [], unmatched_sources: [], snapshot_checked_at: nil, warnings: [],
                                     active_activities: [])
  end
  let(:linker) { instance_double(SeasonBoard::CalendarLinker, call: SeasonBoard::CalendarLinker::Result.new(success: true, sql_path: '/x/0042-link.sql')) }

  around(:each) { |example| I18n.with_locale(:en) { example.run } }

  before(:each) do
    allow(SeasonBoard::Builder).to receive_messages(latest_season: season, new: instance_double(SeasonBoard::Builder, call: result))
    allow(SeasonBoard::CalendarLinker).to receive(:new).and_return(linker)
    SeasonBoard::Snapshot.invalidate!(season)
    sign_in_admin(prepare_admin_user)
  end

  context 'with a green DB sync check' do
    before(:each) { FactoryBot.create(:ops_db_fingerprint, api_base_url: Shell::APITarget.configured_url) }

    it 'says where the FIN id and the link come from and asks for its own tick, without the DB sync part' do
      post(season_board_link_path, params: { fin_event_id: '150112', calendar_id: '321' })
      expect(response).to have_http_status(:unprocessable_content)
      page = response.parsed_body
      expect(page.at_css('#season-board-confirm-adopted').text.squish).to eq(
        I18n.t('season_board.link_adopted_confirm.text', file: '20261125-262-2-FIN-calendar.csv', date: '25/11/2026', fin_event_id: '150112')
      )
      expect(page.at_css('form#frm-season-board-confirm-link input#adopted_ack[required]')).to be_present
      expect(page.at_css('input#drift_ack')).to be_nil
      expect(page.at_css('#drift-indicator')).to be_nil
      expect(SeasonBoard::CalendarLinker).not_to have_received(:new)
    end

    it 'links with the tick, using the adopted FIN id and link' do
      post(season_board_link_path, params: { fin_event_id: '150112', calendar_id: '321', adopted_ack: '1' })
      expect(response).to redirect_to(season_board_path)
      expect(SeasonBoard::CalendarLinker).to have_received(:new).with(season:, calendar_id: 321, fin_event_id: '150112', results_link: adopted_url)
    end
  end

  context 'with a DB sync warning' do
    before(:each) { FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: Shell::APITarget.configured_url) }

    it 'asks for both ticks on the same page' do
      post(season_board_link_path, params: { fin_event_id: '150112', calendar_id: '321', adopted_ack: '1' })
      expect(response).to have_http_status(:unprocessable_content)
      page = response.parsed_body
      expect(page.at_css('#season-board-confirm-adopted')).to be_present
      expect(page.css('form#frm-season-board-confirm-link input[type="checkbox"][required]').pluck('name')).to eq(%w[adopted_ack drift_ack])
      post(season_board_link_path, params: { fin_event_id: '150112', calendar_id: '321', adopted_ack: '1', drift_ack: '1' })
      expect(response).to redirect_to(season_board_path)
      expect(SeasonBoard::CalendarLinker).to have_received(:new).once
    end
  end
end
