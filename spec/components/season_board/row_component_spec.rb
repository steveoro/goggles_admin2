# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::RowComponent, type: :component do
  include ActiveSupport::Testing::TimeHelpers

  around(:each) do |example|
    I18n.with_locale(:en) { travel_to(Time.zone.local(2026, 11, 8, 9, 30)) { example.run } }
  end

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

  def action(kind, **params)
    SeasonBoard::NextAction.new(kind:, params: { fin_event_id: '150091' }.merge(params))
  end

  def entry(kind: :crawl, status: :queued, origin: :auto, **attrs)
    SeasonBoard::ActivityLog::Entry.new(
      fin_event_id: '150091', kind:, origin:, status:, queued_at: Time.zone.local(2026, 11, 8, 9, 5), started_at: nil,
      finished_at: nil, url: nil, message: nil, **attrs
    )
  end

  def orphan(id)
    SeasonBoard::DbIndex::CalendarInfo.new(
      id:, fin_event_id: nil, meeting_id: nil, meeting_code: "code-#{id}", meeting_name: "Orphan #{id}", meeting_place: nil,
      scheduled_date: Date.new(2026, 11, 8), year: 2026, month: 11, cancelled: false, results_link: nil, meeting: nil
    )
  end

  def render_row(row, orphans: [])
    render_inline(described_class.new(row:, orphans:, csrf_token: 'tok123'))
  end

  describe 'columns' do
    subject(:page) do
      render_row(build_row(meeting_id: 77, meeting_description: 'Local desc', mir_count: 12, mrr_count: 3,
                           calendar_id: 5, state: :structure_committed, flags: %i[pushed busy]))
    end

    it 'links the meeting name to the FIN URL' do
      expect(page.css('td a').first['href']).to eq('https://www.federnuoto.it/#/risultati/150091:trofeo-test')
    end

    it 'shows the local meeting with the MIR/MRR badges' do
      expect(page.text).to include('#77', 'Local desc', 'MIR 12', 'MRR 3')
    end

    it 'shows the state badge & the flags (except busy) with tooltips' do
      expect(page.css('span.badge').map(&:text).join).to include('Structure committed', 'pushed')
      expect(page.css('[data-flag="pushed"]').first['title']).to be_present
      expect(page.css('[data-flag="busy"]')).to be_empty
    end
  end

  describe 'actions' do
    it 'posts the FIN id only, with the token, for :crawl' do
      page = render_row(build_row(next_action: action(:crawl, url: 'https://x')))
      form = page.css('form').first
      expect(form['action']).to eq('/season_board/crawl')
      expect(form.css('input[name=fin_event_id]').first['value']).to eq('150091')
      expect(form.css('input[name=authenticity_token]').first['value']).to eq('tok123')
      expect(form.css('input[name=url]')).to be_empty
    end

    it 'posts to the crawl action for :check_results' do
      page = render_row(build_row(state: :structure_committed, next_action: action(:check_results)))
      expect(page.css('form').first['action']).to eq('/season_board/crawl')
      expect(page.text).to include('Check for results')
    end

    it 'posts to the extract action for :extract_manifest' do
      page = render_row(build_row(next_action: action(:extract_manifest, pdf_path: '/x.pdf')))
      expect(page.css('form').first['action']).to eq('/season_board/extract')
    end

    it 'links the Phase 1 Data-Fix step for the review actions' do
      %i[review_results review_structure review_header].each do |kind|
        page = render_row(build_row(next_action: action(kind, file_path: '/data/res.json')))
        expect(page.css('a.btn').first['href']).to eq('/data_fix/review_sessions?file_path=%2Fdata%2Fres.json&phase_v2=1')
      end
    end

    it 'maps the phase of :resume_review to the matching Data-Fix step' do
      {
        1 => '/data_fix/review_sessions?file_path=%2Fa.json&phase_v2=1', 2 => '/data_fix/review_teams?file_path=%2Fa.json&phase2_v2=1',
        3 => '/data_fix/review_swimmers?file_path=%2Fa.json&phase3_v2=1', 4 => '/data_fix/review_events?file_path=%2Fa.json&phase4_v2=1',
        5 => '/data_fix/review_results?file_path=%2Fa.json&phase5_v2=1'
      }.each do |phase, href|
        page = render_row(build_row(state: :in_review, state_detail: { phase: }, next_action: action(:resume_review, file_path: '/a.json', phase:)))
        expect(page.css('a.btn').first['href']).to eq(href)
        expect(page.text).to include("Resume step #{phase}", "In review (step #{phase})")
      end
    end

    it 'links the Push page for :push' do
      page = render_row(build_row(state: :sql_pending, next_action: action(:push, sql_path: '/x.sql', sql_paths: ['/x.sql'])))
      expect(page.css('a.btn').first['href']).to eq('/push/index')
    end

    it 'renders the inline link form with the orphans for :link' do
      page = render_row(build_row(state: :archived_unlinked, next_action: action(:link, bases: ['a'])), orphans: [orphan(9), orphan(10)])
      form = page.css('form').first
      expect(form['action']).to eq('/season_board/link')
      expect(form.css('option').map(&:text)).to include('Select a calendar row...', '9 - code-9 - 2026-11-08 - Orphan 9')
      expect(page.css('details')).to be_empty
    end

    it 'offers the secondary link control only to unmatched rows when orphans exist' do
      row = build_row(next_action: action(:crawl))
      expect(render_row(row, orphans: [orphan(9)]).css('details form[action="/season_board/link"]').size).to eq(1)
      expect(render_row(row).css('details')).to be_empty
      expect(render_row(build_row(calendar_id: 5, next_action: action(:crawl)), orphans: [orphan(9)]).css('details')).to be_empty
    end

    it 'renders no control for rows without next action' do
      page = render_row(build_row(state: :cancelled))
      expect(page.css('form, a.btn, button')).to be_empty
    end

    it 'disables the action while the row is busy' do
      row = build_row(busy: true, next_action: action(:crawl),
                      activity: { crawl: entry(status: :running, origin: :auto, started_at: Time.zone.local(2026, 11, 8, 9, 10)), extract: nil })
      page = render_row(row)
      expect(page.css('form')).to be_empty
      expect(page.css('button[disabled]')).not_to be_empty
    end
  end

  describe 'activity badges' do
    def activity_text(crawl: nil, extract: nil, busy: false)
      render_row(build_row(busy:, next_action: action(:crawl), activity: { crawl:, extract: })).text
    end

    it 'shows a queued automatic crawl' do
      expect(activity_text(crawl: entry(status: :queued, origin: :auto), busy: true)).to include('Auto-crawl queued')
    end

    it 'shows a queued manual crawl' do
      expect(activity_text(crawl: entry(status: :queued, origin: :manual), busy: true)).to include('Crawl queued')
    end

    it 'shows a running crawl with its origin and start time' do
      running = entry(status: :running, origin: :auto, started_at: Time.zone.local(2026, 11, 8, 9, 10))
      expect(activity_text(crawl: running, busy: true)).to include('Auto-crawling since 09:10')
      manual = entry(status: :running, origin: :manual, started_at: Time.zone.local(2026, 11, 8, 9, 10))
      expect(activity_text(crawl: manual, busy: true)).to include('Crawling since 09:10')
    end

    it 'shows an extraction in progress' do
      expect(activity_text(extract: entry(kind: :extract, status: :queued), busy: true)).to include('Extraction queued')
    end

    it 'shows the failure message with its time' do
      failed = entry(status: :failed, finished_at: Time.zone.local(2026, 11, 8, 10, 0), message: 'timeout after 30 min')
      expect(activity_text(crawl: failed)).to include('Failed 08/11 10:00: timeout after 30 min')
    end

    it 'shows the last success as muted text' do
      done = entry(status: :done, finished_at: Time.zone.local(2026, 11, 8, 10, 0))
      page = render_row(build_row(next_action: action(:crawl), activity: { crawl: done, extract: nil }))
      expect(page.css('.text-muted').map(&:text).join).to include('last crawl OK 08/11 10:00')
    end

    it 'shows a stale running crawl as a "seems stuck" warning, keeping the action enabled' do
      stuck = entry(status: :running, origin: :auto, started_at: Time.zone.local(2026, 11, 8, 8, 40))
      expect(stuck).to be_stale
      page = render_row(build_row(next_action: action(:crawl), activity: { crawl: stuck, extract: nil }))
      expect(page.css('span.badge-warning').map(&:text).join).to include('Crawl seems stuck since 08:40')
      expect(page.css('form[action="/season_board/crawl"] button[type=submit]')).not_to be_empty
      expect(page.css('button[disabled]')).to be_empty
    end

    it 'shows a stale queued extraction as stuck, with the day when not today' do
      stuck = entry(kind: :extract, status: :queued, queued_at: Time.zone.local(2026, 11, 7, 18, 0))
      expect(stuck).to be_stale
      text = render_row(build_row(next_action: action(:extract_manifest), activity: { crawl: nil, extract: stuck })).text
      expect(text).to include('Extraction seems stuck since 07/11 18:00')
    end

    it 'shows nothing when idle' do
      expect(render_row(build_row).css('td')[5].text.strip).to be_empty
    end
  end
end
