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

      it 'highlights the Season board in the sidebar' do
        expect(page.css('.app-sidebar a.active').pluck('href')).to eq([season_board_path])
      end

      it 'shows the header, the warnings and the activity strip' do
        expect(response.body).to include(season.description, 'Something to look at', 'Background activity')
        expect(response.body).to include('FIN calendar last checked')
      end

      it 'shows no pending board SQL notice when there is none' do
        expect(page.at_css('#season-board-sql-pending')).to be_nil
      end

      context 'with board SQL scripts awaiting push' do
        let(:result) do
          SeasonBoard::Builder::Result.new(
            season:, rows:, orphans:, unmatched_sources: [], snapshot_checked_at: nil, warnings: [], active_activities: [],
            pending_board_sql_paths: ['/d/0001-calendar_link-1-2.sql', '/d/0002-season_board_backfill-262.sql']
          )
        end

        it 'shows their count in the header with a link to the Outbox, focused on the first one' do
          notice = page.at_css('#season-board-sql-pending')
          expect(notice.text).to include('2 SQL scripts awaiting push')
          expect(notice.at_css('a')['href']).to eq(outbox_path(focus: '0001-calendar_link-1-2.sql'))
        end
      end

      context 'with a pending source whose FIN id is on no board row (0.10.103)' do
        let(:data_dir) { Dir.mktmpdir('board-off-board') }
        let(:result) do
          dir = File.join(data_dir, 'results.new', season.id.to_s)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'eventi-only.json'),
                     { 'layoutType' => 2, 'sections' => [], 'meetingURL' => 'https://www.federnuoto.it/x.html#/risultati/150700:eventi-only.html' }.to_json)
          entries = SeasonBoard::DiskIndex.new(season_id: season.id, data_dir:).entries.values
          SeasonBoard::Builder::Result.new(season:, rows:, orphans:, unmatched_sources: [], snapshot_checked_at: nil, warnings: [],
                                           active_activities: [], off_board_sources: entries)
        end

        after(:each) { FileUtils.rm_rf(data_dir) }

        it 'lists it under the board with its actions (no board warning any more)' do
          line = page.at_css('#season-board-off-board li[data-off-board-fin-event-id="150700"]')
          expect(line.text).to include('FIN 150700', 'eventi-only')
          expect(line.at_css('form[action="/sources/prepare"] input[name="authenticity_token"]')).to be_present
          expect(page.at_css('#season-board-warnings')).to be_nil
        end
      end

      it 'renders the right action control for each state' do
        crawl_form = page.at_css('#season-board-row-1 form[action="/season_board/crawl"]')
        expect(crawl_form.at_css('input[name=fin_event_id]')['value']).to eq('1')
        expect(page.at_css('#season-board-row-2 form[action="/season_board/extract"]')).to be_present
        expect(page.at_css('#season-board-row-3 a.btn')['href']).to eq(review_sessions_path(file_path: '/d/r.json', phase_v2: 1))
        expect(page.at_css('#season-board-row-4 a.btn')['href']).to eq(review_swimmers_path(file_path: '/d/p.json', phase3_v2: 1))
        expect(page.at_css('#season-board-row-5 a.btn')['href']).to eq(outbox_path(focus: 's.sql'))
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

    describe 'filter persistence (cookie season_board_filters, SeasonBoard::Filters)' do
      def stored_filters
        raw = cookies[SeasonBoard::Filters.cookie_name]
        raw.present? ? JSON.parse(CGI.unescape(raw)) : nil
      end

      def visible_names = response.parsed_body.css('#season-board-table tbody tr[id^="season-board-row-"]').map { |tr| tr.at_css('td:nth-child(2)').text.strip }

      it 'marks every chip and toggle link as an explicit choice (filters=1)' do
        get(season_board_path(locale: 'en'))
        links = response.parsed_body.css('#season-board-filters a')
        expect(links).not_to be_empty
        expect(links.pluck('href')).to all(include('filters=1'))
        expect(response.parsed_body.at_css('#season-board-chip-all')['data-chip-selected']).to eq('true')
      end

      it 'stores an explicit chip and restores it on a request without filter params (the sidebar link)' do
        get(season_board_path(state: 'manifest_pending', filters: 1, locale: 'en'))
        expect(stored_filters).to eq('state' => 'manifest_pending')

        get(season_board_path(locale: 'en'))
        expect(visible_names).to eq(['To extract'])
        chip = response.parsed_body.at_css('[data-state-chip="manifest_pending"]')
        expect(chip['data-chip-selected']).to eq('true')
        expect(chip['class']).to include('text-bg-primary')
        expect(response.parsed_body.at_css('#season-board-chip-all')['data-chip-selected']).to eq('false')
      end

      it 'stores the toggles too, and the "All" chip clears the state chip (the cookie goes when nothing is left)' do
        get(season_board_path(state: 'results_ready', show_done: 1, filters: 1))
        expect(stored_filters).to eq('state' => 'results_ready', 'show_done' => true)

        get(season_board_path(show_done: 1, filters: 1))
        expect(stored_filters).to eq('show_done' => true)
        get(season_board_path)
        expect(visible_names).to include('Old and done', 'To crawl')

        get(season_board_path(filters: 1))
        expect(stored_filters).to be_nil
        get(season_board_path)
        expect(visible_names).to include('To crawl', 'To extract')
        expect(visible_names).not_to include('Old and done', 'Unlinked row')
      end

      it 'lets a deep link with filter params (no marker) win, and stores it' do
        get(season_board_path(state: 'manifest_pending', filters: 1))
        get(season_board_path(state: 'sql_pending'))
        expect(visible_names).to eq(['To push'])
        expect(stored_filters).to eq('state' => 'sql_pending')
      end

      it 'never stores from the live refresh (frame=1), which uses its params or the cookie' do
        get(season_board_path(state: 'manifest_pending', filters: 1))
        get(season_board_path(frame: 1, state: 'sql_pending', filters: 1))
        expect(visible_names).to eq(['To push'])
        expect(stored_filters).to eq('state' => 'manifest_pending')
        get(season_board_path(frame: 1))
        expect(visible_names).to eq(['To extract'])
      end

      it 'lands on the stored chip after a POST redirect (e.g. a crawl)' do
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
        get(season_board_path(state: 'manifest_pending', filters: 1))
        post(season_board_crawl_path, params: { fin_event_id: '1' })
        expect(response).to redirect_to(season_board_path)
        follow_redirect!
        expect(visible_names).to eq(['To extract'])
      end

      it 'ignores a garbage cookie: bad JSON, unknown keys and states, non-boolean toggles, an oversized value' do
        [
          'not json at all', '[1,2,3]', '"just a string"', '%FF', '%7B%22state%22%3A%22%FF%22%7D',
          { 'state' => 'bogus', 'show_done' => 'yes', 'evil' => '<script>' }.to_json,
          { 'state' => 'manifest_pending', 'pad' => 'x' * 400 }.to_json
        ].each do |raw|
          cookies[SeasonBoard::Filters.cookie_name] = raw
          get(season_board_path)
          expect(response).to have_http_status(:success)
          expect(visible_names).to include('To crawl', 'To extract')
          expect(visible_names).not_to include('Old and done', 'Unlinked row')
        end
      end

      it 'reads only the known keys of a valid cookie' do
        cookies[SeasonBoard::Filters.cookie_name] = { 'state' => 'manifest_pending', 'show_done' => true, 'other' => 1 }.to_json
        get(season_board_path)
        expect(visible_names).to eq(['To extract'])
      end

      it 'keeps showing the remembered chip when no row is left in its state (count 0), so that it can be cleared' do
        get(season_board_path(state: 'prepare_failed', filters: 1))
        get(season_board_path(locale: 'en'))
        chip = response.parsed_body.at_css('[data-state-chip="prepare_failed"]')
        expect(chip.text).to include('(0)')
        expect(chip['data-chip-selected']).to eq('true')
        expect(response.body).to include(I18n.t('season_board.filters.none_visible'))
      end

      describe 'row links (row=<fin_event_id>, SeasonBoard::ActionPaths.board_row_path)' do
        before(:each) { get(season_board_path(state: 'manifest_pending', filters: 1)) }

        it 'shows the whole board for that request when the remembered chip would hide the row, storing nothing' do
          get(SeasonBoard::ActionPaths.board_row_path('1'))
          expect(visible_names).to include('To crawl', 'To extract', 'Unlinked row', 'Old and done')
          expect(response.parsed_body.at_css('#season-board-chip-all')['data-chip-selected']).to eq('true')
          expect(stored_filters).to eq('state' => 'manifest_pending')
          get(season_board_path)
          expect(visible_names).to eq(['To extract'])
        end

        it 'keeps the remembered chip when it shows the row' do
          get(SeasonBoard::ActionPaths.board_row_path('2'))
          expect(visible_names).to eq(['To extract'])
          expect(response.parsed_body.at_css('[data-state-chip="manifest_pending"]')['data-chip-selected']).to eq('true')
        end

        it 'keeps the remembered chip for an unknown row, and lets a row link with a state stay explicit (stored)' do
          get(SeasonBoard::ActionPaths.board_row_path('999'))
          expect(visible_names).to eq(['To extract'])
          get(SeasonBoard::ActionPaths.board_row_path('8', state: :committed_with_results))
          expect(visible_names).to eq(['Old and done'])
          expect(stored_filters).to eq('state' => 'committed_with_results')
        end
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

    describe 'GET /season_board?frame=1 (live refresh)' do
      it 'renders only the rows frame, without the layout, keeping the filters' do
        get(season_board_path(frame: 1, state: 'manifest_pending', locale: 'en'))
        expect(response).to have_http_status(:success)
        page = response.parsed_body
        expect(page.at_css('turbo-frame#season-board-rows #season-board-table')).to be_present
        expect(page.at_css('.app-sidebar, #season-board-sql-pending, [data-controller="season-board"]')).to be_nil
        expect(response.body).not_to include('<html', 'FIN calendar last checked')
        expect(response.body).to include('To extract')
        expect(response.body).not_to include('To crawl')
      end
    end

    describe 'board summary (SeasonBoard::Snapshot)' do
      let(:stored_rows) do
        [build_row(fin_event_id: '1', name: 'To crawl', state: :link_not_crawled, next_action: action(:crawl, '1', url: 'u1'),
                   url: 'https://stored.example/1')]
      end

      def store_summary(rows_to_store)
        stored = SeasonBoard::Builder::Result.new(season:, rows: rows_to_store, orphans: [], unmatched_sources: [],
                                                  snapshot_checked_at: nil, warnings: [], active_activities: [])
        SeasonBoard::Snapshot.store!(season, stored)
      end

      it 'is stored by the board GET' do
        get(season_board_path, params: { locale: 'en' })
        summary = SeasonBoard::Snapshot.read(season)
        expect(summary).to be_stored
        expect(summary.rows.map(&:fin_event_id)).to eq(rows.map(&:fin_event_id))
        expect(summary.state_counts).to include(link_not_crawled: 1, manifest_pending: 1)
      end

      it 'is used by a POST with no board build when fresh (URL from the stored row)' do
        store_summary(stored_rows)
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
        post(season_board_crawl_path, params: { fin_event_id: '1', url: 'https://evil.example/' })
        expect(SeasonBoard::Builder).not_to have_received(:new)
        expect(response).to redirect_to(season_board_path)
        expect(SeasonBoard::Scheduler).to have_received(:crawl!)
          .with(season_id: season.id, fin_event_id: '1', url: 'https://stored.example/1', origin: :manual)
      end

      it 'is rebuilt by a POST when its fingerprint is stale' do
        store_summary(stored_rows)
        record = Ops::Snapshot.read(SeasonBoard::Snapshot.key_for(season))
        record.update!(payload: record.payload.merge('fingerprint' => 'stale'))
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
        post(season_board_crawl_path, params: { fin_event_id: '1' })
        expect(SeasonBoard::Builder).to have_received(:new).once
        expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(hash_including(url: 'https://fin.example/1'))
      end

      it 'is built live by a POST without the ops DB' do
        allow(Ops).to receive(:available?).and_return(false)
        allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
        post(season_board_crawl_path, params: { fin_event_id: '1' })
        expect(SeasonBoard::Builder).to have_received(:new).once
        expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(hash_including(url: 'https://fin.example/1'))
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
        expect(SeasonBoard::Scheduler).to have_received(:extract!).with(hash_including(season_id: season.id, fin_event_id: '2', engine: nil, pdf_path: '/x.pdf'))
      end

      it 'passes an allowed engine' do
        allow(SeasonBoard::Scheduler).to receive(:extract!).and_return(true)
        post(season_board_extract_path, params: { fin_event_id: '2', engine: 'ollama' })
        expect(SeasonBoard::Scheduler).to have_received(:extract!).with(hash_including(season_id: season.id, fin_event_id: '2', engine: 'ollama'))
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
      let(:green_check) { FactoryBot.create(:ops_db_fingerprint, api_base_url: Shell::APITarget.configured_url) }

      # (the DB sync gate, scope :board_write, passes on a fresh green check)
      before(:each) { green_check }

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

      describe 'DB sync gate (scope :board_write, phase 08)' do
        let(:green_check) { FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: Shell::APITarget.configured_url) }

        it 'asks for the tick on a warning (red included) before linking, re-posting the same link' do
          allow(SeasonBoard::CalendarLinker).to receive(:new)
          post(season_board_link_path, params: { fin_event_id: '6', calendar_id: '321' })
          expect(response).to have_http_status(:unprocessable_content)
          form = response.parsed_body.at_css('form#frm-season-board-confirm-link')
          expect(form['action']).to eq(season_board_link_path)
          expect(form.at_css('input[name="fin_event_id"]')['value']).to eq('6')
          expect(form.at_css('input[name="calendar_id"]')['value']).to eq('321')
          expect(form.at_css('input#drift_ack[required]')).to be_present
          expect(response.parsed_body.at_css('#season-board-confirm-link #drift-indicator')['data-drift-verdict']).to eq('red')
          expect(SeasonBoard::CalendarLinker).not_to have_received(:new)
        end

        it 'links with the tick' do
          allow(SeasonBoard::CalendarLinker).to receive(:new).and_return(linker)
          allow(linker).to receive(:call).and_return(SeasonBoard::CalendarLinker::Result.new(success: true, sql_path: '/x/y/0042-link.sql'))
          post(season_board_link_path, params: { fin_event_id: '6', calendar_id: '321', drift_ack: '1' })
          expect(response).to redirect_to(season_board_path)
          expect(SeasonBoard::CalendarLinker).to have_received(:new)
        end
      end
    end

    describe 'pipeline automation (phase 10)' do
      let(:rows) do
        [
          build_row(fin_event_id: '11', name: 'Failed prep', state: :prepare_failed, state_detail: { phase: 4, message: 'solver exploded' },
                    next_action: action(:prepare, '11', file_path: '/d/262/f.json'), url: 'https://fin.example/11'),
          build_row(fin_event_id: '12', name: 'Needs a look', state: :needs_review, state_detail: { step: 3, count: 4, blocked: false },
                    next_action: action(:resume_review, '12', file_path: '/d/262/n.json', phase: 3, filter_state: 'review'),
                    url: 'https://fin.example/12'),
          build_row(fin_event_id: '13', name: 'All clean', state: :ready_to_commit, state_detail: { new_teams: 2, new_swimmers: 37 },
                    next_action: action(:commit, '13', file_path: '/d/262/r.json'), url: 'https://fin.example/13'),
          build_row(fin_event_id: '14', name: 'Held one', state: :results_ready, flags: [:prepare_held],
                    next_action: action(:review_results, '14', file_path: '/d/262/h.json'), url: 'https://fin.example/14'),
          build_row(fin_event_id: '15', name: 'To push', state: :sql_pending, next_action: action(:push, '15', sql_path: '/s.sql', sql_paths: ['/s.sql']),
                    url: 'https://fin.example/15')
        ]
      end
      let(:page) { response.parsed_body }

      describe 'GET /season_board' do
        before(:each) { get(season_board_path, params: { locale: 'en' }) }

        it 'renders the three states with their details' do
          expect(page.at_css('#season-board-row-11 .badge').text).to eq('Preparation failed at step 4: solver exploded')
          expect(page.at_css('#season-board-row-12 .badge').text).to eq('Needs review at step 3 · 4 issues')
          expect(page.at_css('#season-board-row-13 .badge').text).to eq('Ready to commit · +2 teams, +37 swimmers')
        end

        it 'pins the Retry form (POST season_board/prepare) and the Commit link (the commit summary, never a commit)' do
          retry_form = page.at_css('#season-board-row-11 form[action="/season_board/prepare"]')
          expect(retry_form.at_css('input[name=fin_event_id]')['value']).to eq('11')
          expect(retry_form.at_css('button').text.strip).to eq('Retry')
          expect(page.at_css('#season-board-row-13 a.btn')['href']).to eq(data_fix_commit_summary_path(file_path: '/d/262/r.json'))
          expect(page.at_css('#season-board-row-12 a.btn')['href']).to eq(review_swimmers_path(file_path: '/d/262/n.json', phase3_v2: 1, filter_state: 'review'))
        end

        it 'offers Prepare as a secondary action, and the hold toggle on the rows with a source' do
          expect(page.at_css('#season-board-row-12 [data-pipeline-action="prepare"]')).to be_present
          expect(page.at_css('#season-board-row-13 [data-pipeline-action="prepare"]')).to be_nil
          expect(page.at_css('#season-board-row-13 [data-pipeline-action="hold"]')).to be_present
          # ("Auto-prepare" switch: on = not held; flipping it posts hold=1 when on, hold=0 when off)
          expect(page.at_css('#season-board-row-13 form[action="/season_board/hold"] input[role=switch]')['checked']).to be_present
          held = page.at_css('#season-board-row-14 form[action="/season_board/hold"]')
          expect(held.at_css('input[role=switch][name=hold]').to_h.slice('value', 'checked')).to eq('value' => '0')
          expect(held.at_css('input[type=hidden][name=hold]')['value']).to eq('1')
          expect(page.at_css('#season-board-row-14 [data-flag="prepare_held"]')).to be_present
          expect(page.at_css('#season-board-row-15 .season-board-pipeline-actions')).to be_nil
        end

        it 'shows the automation switches and the Prepare all button in the header' do
          expect(page.at_css('#season-board-automation #automation-switches-season_board [data-automation-switch="auto_prepare"]')).to be_present
          expect(page.at_css('form[action="/season_board/prepare_all"] button')).to be_present
        end
      end

      describe 'POST /season_board/prepare' do
        it 'queues an operator prepare of the row source (never a commit)' do
          allow(SeasonBoard::Scheduler).to receive(:prepare!).and_return(instance_double(Ops::PipelineRun))
          post(season_board_prepare_path, params: { fin_event_id: '11', file_path: '/evil.json' })
          expect(response).to redirect_to(season_board_path(anchor: 'season-board-row-11'))
          expect(flash[:info]).to eq(I18n.t('pipeline_automation.flash.prepare_queued', fin_event_id: '11'))
          expect(SeasonBoard::Scheduler).to have_received(:prepare!)
            .with(season_id: season.id, source_path: '/d/262/f.json', origin: :operator, fin_event_id: '11')
        end

        it 'warns when the Scheduler refuses (busy) and when the row has no source' do
          allow(SeasonBoard::Scheduler).to receive(:prepare!).and_return(false)
          post(season_board_prepare_path, params: { fin_event_id: '11' })
          expect(flash[:warning]).to eq(I18n.t('pipeline_automation.flash.prepare_busy', fin_event_id: '11'))
          post(season_board_prepare_path, params: { fin_event_id: '15' })
          expect(flash[:warning]).to eq(I18n.t('pipeline_automation.flash.no_source', fin_event_id: '15'))
        end
      end

      describe 'POST /season_board/hold' do
        it 'holds and releases the row source, recording an event' do
          post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' })
          source = Ops::PipelineSource.find_by(season_id: 262, base: 'r')
          expect(source.auto_prepare).to be false
          expect(Ops::Event.order(:id).last).to have_attributes(kind: 'automation.row_held', subject_key: '13')
          post(season_board_hold_path, params: { fin_event_id: '13', hold: '0' })
          expect(source.reload.auto_prepare).to be true
        end

        it 'redirects a plain request to the row, the stored filters restored by the board' do
          get(season_board_path(state: 'ready_to_commit', filters: 1))
          post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' })
          expect(response).to redirect_to(season_board_path(anchor: 'season-board-row-13'))
          follow_redirect!
          expect(page.css('#season-board-table tbody tr[id^="season-board-row-"]').pluck('id')).to eq(['season-board-row-13'])
        end

        describe 'a Turbo request (the row "Auto-prepare" switch)' do
          let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }

          def streams = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')

          def stream(target) = streams.find { |node| node['target'] == target }

          def template(target) = Nokogiri::HTML5.fragment(stream(target).at_css('template').inner_html)

          before(:each) do
            # (a live build: the hold shows on the row once stored)
            allow(SeasonBoard::Builder).to receive(:new) do
              held = Ops::PipelineSource.find_by(season_id: 262, base: 'r')&.auto_prepare == false
              built_rows = rows.map { |row| row.fin_event_id == '13' && held ? row.with(flags: [:prepare_held]) : row }
              instance_double(SeasonBoard::Builder, call: result.with(rows: built_rows))
            end
          end

          it 'answers with the content of the rows frame (stored filters kept) and the toasts' do # rubocop:disable RSpec/MultipleExpectations
            get(season_board_path(state: 'ready_to_commit', filters: 1))
            post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' }, headers: turbo_headers)
            expect(response).to have_http_status(:ok)
            expect(response.media_type).to eq('text/vnd.turbo-stream.html')
            expect(streams.to_h { |node| [node['target'], node['action']] })
              .to eq('season-board-rows' => 'update', 'flash-messages-container' => 'update')
            content = template('season-board-rows')
            expect(content.css('tr[id^="season-board-row-"]').pluck('id')).to eq(['season-board-row-13'])
            expect(content.at_css('[data-state-chip="ready_to_commit"]')['data-chip-selected']).to eq('true')
            switch = content.at_css('#season-board-hold-13')
            expect(switch['checked']).to be_nil
            expect(content.at_css('#season-board-row-13 [data-flag="prepare_held"]')).to be_present
            expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.held', fin_event_id: '13'))
            expect(Ops::PipelineSource.find_by(season_id: 262, base: 'r').auto_prepare).to be false

            post(season_board_hold_path, params: { fin_event_id: '13', hold: '0' }, headers: turbo_headers)
            expect(template('season-board-rows').at_css('#season-board-hold-13')['checked']).to be_present
            expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.released', fin_event_id: '13'))
          end

          it 'keeps the stored board filter (the stream shows it, the cookie is unchanged)' do
            get(season_board_path(state: 'ready_to_commit', filters: 1))
            cookie = cookies[SeasonBoard::Filters.cookie_name]
            post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' }, headers: turbo_headers)
            expect(cookies[SeasonBoard::Filters.cookie_name]).to eq(cookie)
            expect(template('season-board-rows').at_css('[data-state-chip="ready_to_commit"]')['data-chip-selected']).to eq('true')
          end

          it 'redirects without a season (nothing stored: the switch must not keep an unstored position)' do
            allow(SeasonBoard::Builder).to receive(:latest_season).and_return(nil)
            post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' }, headers: turbo_headers)
            expect(response).to redirect_to(season_board_path)
            expect(flash[:warning]).to eq(I18n.t('season_board.flash.no_season'))
            expect(Ops::PipelineSource.count).to eq(0)
          end

          it 'answers an unknown row or a row without a source with the toast (and the rows as they are)' do
            post(season_board_hold_path, params: { fin_event_id: '999', hold: '1' }, headers: turbo_headers)
            expect(stream('flash-messages-container').text).to include(I18n.t('season_board.flash.unknown_row', fin_event_id: '999'))
            expect(stream('season-board-rows')).to be_present

            post(season_board_hold_path, params: { fin_event_id: '15', hold: '1' }, headers: turbo_headers)
            expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.no_source', fin_event_id: '15'))
          end

          it 'shows a failed write as an error toast, the switch keeping its state' do
            allow(Ops::PipelineSource).to receive(:for_path!).and_raise(ActiveRecord::StatementInvalid, 'locked')
            post(season_board_hold_path, params: { fin_event_id: '13', hold: '1' }, headers: turbo_headers)
            expect(stream('flash-messages-container').text).to include(I18n.t('pipeline_automation.flash.hold_failed', fin_event_id: '13'))
            expect(template('season-board-rows').at_css('#season-board-hold-13')['checked']).to be_present
          end
        end
      end

      describe 'POST /season_board/prepare_all' do
        it 'queues a planner pass' do
          expect { post(season_board_prepare_all_path) }.to have_enqueued_job(PipelinePlannerJob).with(trigger: 'board')
          expect(response).to redirect_to(season_board_path)
        end

        it 'refuses while the automation is paused' do
          DataFix::Automation.store!(:auto_prepare, false)
          expect { post(season_board_prepare_all_path) }.not_to have_enqueued_job(PipelinePlannerJob)
          expect(flash[:warning]).to eq(I18n.t('pipeline_automation.flash.paused'))
        end
      end
    end
  end
end
