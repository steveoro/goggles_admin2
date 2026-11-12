# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoardController do
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
                url: 'https://fin.example/3'),
      build_row(fin_event_id: '4', name: 'In progress', state: :in_review, state_detail: { phase: 3 },
                next_action: action(:resume_review, '4', file_path: '/d/p.json', phase: 3), url: 'https://fin.example/4'),
      build_row(fin_event_id: '5', name: 'To push', state: :sql_pending, next_action: action(:push, '5', sql_path: '/s.sql', sql_paths: ['/s.sql']),
                url: 'https://fin.example/5'),
      build_row(fin_event_id: '6', name: 'To link', state: :archived_unlinked, next_action: action(:link, '6', bases: ['b']),
                url: 'https://fin.example/6'),
      build_row(fin_event_id: nil, name: 'Unlinked row', state: :not_linked, url: nil),
      build_row(fin_event_id: '8', name: 'Old and done', state: :committed_with_results, meeting_id: 8, mir_count: 10, mrr_count: 2,
                last_date: Date.new(2026, 1, 1), url: 'https://fin.example/8'),
      build_row(fin_event_id: '9', name: 'Cancelled one', state: :cancelled, url: 'https://fin.example/9')
    ]
  end
  let(:orphans) do
    [
      SeasonBoard::DbIndex::CalendarInfo.new(
        id: 321, fin_event_id: nil, meeting_id: 55, meeting_code: 'orph-code', meeting_name: 'Orphan meeting', meeting_place: nil,
        scheduled_date: Date.new(2026, 10, 1), year: 2026, month: 10, cancelled: false, results_link: nil, meeting: nil
      ),
      SeasonBoard::DbIndex::CalendarInfo.new(
        id: 654, fin_event_id: '150999', meeting_id: 66, meeting_code: 'gone-code', meeting_name: 'Gone from FIN', meeting_place: nil,
        scheduled_date: Date.new(2026, 10, 2), year: 2026, month: 10, cancelled: false, results_link: nil, meeting: nil
      )
    ]
  end
  let(:result) do
    SeasonBoard::Builder::Result.new(
      season:, rows:, orphans:, unmatched_sources: [], snapshot_checked_at: Time.zone.local(2026, 11, 12, 9, 30),
      warnings: ['Something to look at'], active_activities: []
    )
  end

  before(:each) do
    builder = instance_double(SeasonBoard::Builder, call: result)
    allow(SeasonBoard::Builder).to receive_messages(latest_season: season, new: builder)
  end

  context 'with an unlogged user' do
    it 'GET /season_board redirects to the login path' do
      get(season_board_path, params: { locale: 'en' })
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'POST /season_board/crawl redirects to the login path' do
      allow(SeasonBoard::Scheduler).to receive(:crawl!)
      post(season_board_crawl_path, params: { fin_event_id: '1' })
      expect(response).to redirect_to(new_user_session_path)
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end
  end

  context 'with a logged-in user' do
    include AdminSignInHelpers

    around(:each) { |example| I18n.with_locale(:en) { example.run } }

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    describe 'GET /season_board' do
      let(:page) { response.parsed_body }

      before(:each) { get(season_board_path, params: { locale: 'en' }) }

      it 'is successful and wraps the rows in the Turbo frame' do
        expect(response).to have_http_status(:success)
        expect(page.at_css('turbo-frame#season-board-rows #season-board-table')).to be_present
        expect(page.at_css('[data-controller="season-board"]')).to be_present
      end

      it 'shows the header, the warnings and the activity strip' do
        expect(response.body).to include(season.description, 'Something to look at', 'Background activity')
        expect(response.body).to include('FIN calendar last checked')
      end

      it 'renders the right action control for each state' do
        crawl_form = page.at_css('#season-board-row-1 form[action="/season_board/crawl"]')
        expect(crawl_form.at_css('input[name=fin_event_id]')['value']).to eq('1')
        expect(page.at_css('#season-board-row-2 form[action="/season_board/extract"]')).to be_present
        expect(page.at_css('#season-board-row-3 a.btn')['href']).to eq(review_sessions_path(file_path: '/d/r.json', phase_v2: 1))
        expect(page.at_css('#season-board-row-4 a.btn')['href']).to eq(review_swimmers_path(file_path: '/d/p.json', phase3_v2: 1))
        expect(page.at_css('#season-board-row-5 a.btn')['href']).to eq(push_index_path)
        expect(page.at_css('#season-board-row-6 form[action="/season_board/link"] option[value="321"]')).to be_present
        expect(page.at_css('#season-board-row-9 form, #season-board-row-9 a.btn')).to be_nil
      end

      it 'hides the rows without link and the past done rows by default, behind toggles with counts' do
        expect(response.body).not_to include('Unlinked row', 'Old and done')
        expect(response.body).to include('Show rows without a link (1)', 'Show past meetings with results (1)')
      end

      it 'lists the orphan calendar rows in the collapsible table' do
        expect(page.at_css('#orphans-collapse').text).to include('321', 'orph-code', 'Orphan meeting', '55')
      end

      it 'marks the orphans whose FIN id is not on the current calendar' do
        gone = page.at_css('#orphans-collapse tr[data-orphan-id="654"]')
        expect(gone.text).to include('150999', 'FIN id not on the current calendar')
        expect(page.at_css('#orphans-collapse tr[data-orphan-id="321"]').text).not_to include('FIN id not on the current calendar')
      end

      it 'offers only the orphans without FIN id as link targets' do
        options = page.css('#season-board-row-6 form[action="/season_board/link"] option').filter_map { |opt| opt['value'].presence }
        expect(options).to eq(['321'])
        secondary = page.css('#season-board-row-1 details option').filter_map { |opt| opt['value'].presence }
        expect(secondary).to eq(['321'])
      end

      it 'shows a chip with the count for each state' do
        expect(page.at_css('[data-state-chip="link_not_crawled"]').text).to include('(1)')
      end
    end

    describe 'GET /season_board with filters' do
      it 'shows the hidden rows with the toggles' do
        get(season_board_path(show_unlinked: 1, show_done: 1, locale: 'en'))
        expect(response.body).to include('Unlinked row', 'Old and done')
      end

      it 'filters by state' do
        get(season_board_path(state: 'manifest_pending', locale: 'en'))
        expect(response.body).to include('To extract')
        expect(response.body).not_to include('To crawl')
      end
    end

    describe 'GET /season_board with the unlinked-only or empty snapshot' do
      let(:rows) { [] }

      it 'shows the empty message with the check-now action' do
        get(season_board_path, params: { locale: 'en' })
        expect(response).to have_http_status(:success)
        expect(response.body).to include('The FIN calendar snapshot is empty')
        expect(response.parsed_body.at_css('#season-board-empty form[action="/federnuoto_watch/check"]')).to be_present
      end
    end

    describe 'GET /season_board with a missing season' do
      it 'redirects to the home page with a warning' do
        allow(SeasonBoard::Builder).to receive(:latest_season).and_return(nil)
        get(season_board_path, params: { locale: 'en' })
        expect(response).to redirect_to(root_path)
        expect(flash[:warning]).to eq(I18n.t('season_board.flash.no_season'))
      end
    end

    describe 'GET /season_board with busy rows' do
      let(:rows) do
        entry = SeasonBoard::ActivityLog::Entry.new(
          fin_event_id: '1', kind: :crawl, origin: :auto, status: :queued, queued_at: Time.current, started_at: nil,
          finished_at: nil, url: nil, message: nil
        )
        [build_row(fin_event_id: '1', next_action: action(:crawl, '1'), busy: true, flags: [:busy],
                   activity: { crawl: entry, extract: nil })]
      end
      let(:result) do
        SeasonBoard::Builder::Result.new(season:, rows:, orphans: [], unmatched_sources: [], snapshot_checked_at: nil, warnings: [],
                                         active_activities: [rows.first.activity[:crawl]])
      end

      it 'shows the activity, disables the button and marks the frame as busy for the polling fallback' do
        get(season_board_path, params: { locale: 'en' })
        page = response.parsed_body
        expect(response.body).to include('Auto-crawl queued', 'Queued: 1')
        expect(page.at_css('#season-board-row-1 form')).to be_nil
        expect(page.at_css('#season-board-row-1 button[disabled]')).to be_present
        expect(page.at_css('[data-season-board-busy="true"]')).to be_present
      end
    end

    describe 'POST /season_board/crawl' do
      it 'queues the crawl with the URL taken from the board row' do
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
        post(season_board_crawl_path, params: { fin_event_id: '1', url: 'https://evil.example/' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:info]).to eq(I18n.t('season_board.flash.crawl_queued', fin_event_id: '1'))
        expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: season.id, fin_event_id: '1', url: 'https://fin.example/1', origin: :manual)
      end

      it 'refuses an unknown FIN id' do
        allow(SeasonBoard::Scheduler).to receive(:crawl!)
        post(season_board_crawl_path, params: { fin_event_id: '999' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:error]).to eq(I18n.t('season_board.flash.unknown_row', fin_event_id: '999'))
        expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
      end

      it 'warns when a crawl is already queued or running' do
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(false)
        post(season_board_crawl_path, params: { fin_event_id: '1' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:warning]).to eq(I18n.t('season_board.flash.busy', fin_event_id: '1'))
      end

      it 'flashes the error when the job cannot be enqueued' do
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_raise(ActiveRecord::StatementInvalid, 'no such table: solid_queue_jobs')
        post(season_board_crawl_path, params: { fin_event_id: '1' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:error]).to eq(I18n.t('season_board.flash.enqueue_failed', fin_event_id: '1', error: 'no such table: solid_queue_jobs'))
      end
    end

    describe 'POST /season_board/extract' do
      it 'queues the extraction with the default engine' do
        allow(SeasonBoard::Scheduler).to receive(:extract!).and_return(true)
        post(season_board_extract_path, params: { fin_event_id: '2' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:info]).to eq(I18n.t('season_board.flash.extract_queued', fin_event_id: '2'))
        expect(SeasonBoard::Scheduler).to have_received(:extract!).with(season_id: season.id, fin_event_id: '2', engine: nil)
      end

      it 'passes an allowed engine' do
        allow(SeasonBoard::Scheduler).to receive(:extract!).and_return(true)
        post(season_board_extract_path, params: { fin_event_id: '2', engine: 'ollama' })
        expect(SeasonBoard::Scheduler).to have_received(:extract!).with(season_id: season.id, fin_event_id: '2', engine: 'ollama')
      end

      it 'refuses an unsupported engine' do
        allow(SeasonBoard::Scheduler).to receive(:extract!)
        post(season_board_extract_path, params: { fin_event_id: '2', engine: 'rm -rf' })
        expect(flash[:error]).to eq(I18n.t('season_board.flash.invalid_engine', engine: 'rm -rf'))
        expect(SeasonBoard::Scheduler).not_to have_received(:extract!)
      end

      it 'refuses an unknown FIN id' do
        allow(SeasonBoard::Scheduler).to receive(:extract!)
        post(season_board_extract_path, params: { fin_event_id: '999' })
        expect(flash[:error]).to eq(I18n.t('season_board.flash.unknown_row', fin_event_id: '999'))
        expect(SeasonBoard::Scheduler).not_to have_received(:extract!)
      end

      it 'warns when busy' do
        allow(SeasonBoard::Scheduler).to receive(:extract!).and_return(false)
        post(season_board_extract_path, params: { fin_event_id: '2' })
        expect(flash[:warning]).to eq(I18n.t('season_board.flash.busy', fin_event_id: '2'))
      end

      it 'flashes the error when the job cannot be enqueued' do
        allow(SeasonBoard::Scheduler).to receive(:extract!).and_raise(StandardError, 'queue DB missing')
        post(season_board_extract_path, params: { fin_event_id: '2' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:error]).to eq(I18n.t('season_board.flash.enqueue_failed', fin_event_id: '2', error: 'queue DB missing'))
      end
    end

    describe 'POST /season_board/link' do
      let(:linker) { instance_double(SeasonBoard::CalendarLinker) }

      it 'links the calendar using the row URL and reports the SQL file name' do
        allow(SeasonBoard::CalendarLinker).to receive(:new).and_return(linker)
        allow(linker).to receive(:call).and_return(SeasonBoard::CalendarLinker::Result.new(success: true, sql_path: '/x/y/0042-link.sql'))
        post(season_board_link_path, params: { fin_event_id: '6', calendar_id: '321' })
        expect(response).to redirect_to(season_board_path)
        expect(flash[:notice]).to include('0042-link.sql')
        expect(SeasonBoard::CalendarLinker).to have_received(:new).with(season:, calendar_id: 321, fin_event_id: '6', results_link: 'https://fin.example/6')
      end

      it 'reports the linker error' do
        allow(SeasonBoard::CalendarLinker).to receive(:new).and_return(linker)
        allow(linker).to receive(:call).and_return(SeasonBoard::CalendarLinker::Result.new(success: false, error: 'Calendar not found'))
        post(season_board_link_path, params: { fin_event_id: '6', calendar_id: '321' })
        expect(flash[:error]).to eq(I18n.t('season_board.flash.link_failed', error: 'Calendar not found'))
      end

      it 'refuses an unknown FIN id' do
        allow(SeasonBoard::CalendarLinker).to receive(:new)
        post(season_board_link_path, params: { fin_event_id: '999', calendar_id: '321' })
        expect(flash[:error]).to eq(I18n.t('season_board.flash.unknown_row', fin_event_id: '999'))
        expect(SeasonBoard::CalendarLinker).not_to have_received(:new)
      end

      it 'refuses a missing calendar' do
        allow(SeasonBoard::CalendarLinker).to receive(:new)
        post(season_board_link_path, params: { fin_event_id: '6' })
        expect(flash[:warning]).to eq(I18n.t('season_board.flash.link_missing_params'))
        expect(SeasonBoard::CalendarLinker).not_to have_received(:new)
      end
    end
  end
end
