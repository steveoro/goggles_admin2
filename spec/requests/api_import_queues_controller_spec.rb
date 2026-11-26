# frozen_string_literal: true

require 'rails_helper'

RSpec.describe APIImportQueuesController do
  describe 'GET api_import_queues (index)' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get(api_import_queues_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call).with(
          method: :get, url: 'import_queues', jwt: admin_user.jwt,
          params: { page: anything, per_page: anything }
        ).and_return(DummyResponse.new(body: GogglesDb::ImportQueue.all.to_json))
      end

      it 'returns http success' do
        get(api_import_queues_path)
        expect(response).to have_http_status(:success)
      end

      it 'links a pushed SQL batch row to its SQL Outbox script (phase 15 drill-down link)' do
        data_root = Pathname.new(Dir.mktmpdir)
        script = create_sql_script(data_root, 'results.sent/262/0042-x-lt4.sql', seq: 990_042, state: 'sent', remote_iq_id: 9124)
        rows = [{ 'id' => 9124, 'batch_sql' => true, 'done' => true, 'process_runs' => 1 }]
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: rows.to_json))
        get(api_import_queues_path)
        link = response.parsed_body.at_css('td[data-column="outbox"] a[data-drill="outbox_script"]')
        expect(link['href']).to eq(outbox_script_path(script))
        expect(link.text.strip).to eq('0042-x-lt4.sql')
      ensure
        FileUtils.rm_rf(data_root)
      end

      it "shows a batch row's attached file name and an excerpt of its server error (API 0.10.82, phase 08)" do
        error = "ERROR 1062 (23000) at line 412: Duplicate entry '4188003' for key 'PRIMARY' #{'x' * 120}"
        rows = [{ 'id' => 9123, 'batch_sql' => true, 'done' => false, 'process_runs' => 1, 'error_messages' => error,
                  'data_file_name' => '0477-2026-11-22-Trofeo_X-lt4.sql', 'data_file_checksum' => 'q1w2==' }]
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: rows.to_json))
        get(api_import_queues_path)
        row = response.parsed_body.at_css('table.datagrid-table tbody tr')
        expect(row.at_css('td[data-column="data_file_name"]').text.strip).to eq('0477-2026-11-22-Trofeo_X-lt4.sql')
        excerpt = row.at_css('td[data-column="error_excerpt"] span')
        expect(excerpt.text).to start_with('ERROR 1062').and end_with('...')
        expect(excerpt['title']).to eq(error)
      end
    end

    context 'with a logged-in user filtering the list' do
      include AdminSignInHelpers

      before(:each) do
        sign_in_admin(prepare_admin_user)
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: [].to_json))
      end

      def api_params
        params = nil
        expect(APIProxy).to have_received(:call) { |**args| params = args[:params] }
        params
      end

      # The filters go to the API, so that they cover every row and not only the current page.
      it 'asks the API for the rows still to process with done=NO, the applied ones with done=YES, all of them without it' do
        get(api_import_queues_path(import_queues_grid: { done: 'NO' }))
        expect(api_params).to include(done: false)
      end

      it 'asks for the done rows with done=YES' do
        get(api_import_queues_path(import_queues_grid: { done: 'YES' }))
        expect(api_params).to include(done: true)
      end

      it 'sends no done filter when none is chosen, and the SQL batch filter when chosen' do
        get(api_import_queues_path(import_queues_grid: { batch_sql: 'YES' }))
        expect(api_params).not_to have_key(:done)
        expect(api_params).to include(batch_sql: true)
      end
    end

    context 'with a logged-in user looking at SQL batch rows' do
      include AdminSignInHelpers

      # (a real micro-transaction row of the test DB: its text label parses its request data)
      let(:micro_row) { GogglesDb::ImportQueue.where(batch_sql: false).first || FactoryBot.create(:import_queue) }

      before(:each) { sign_in_admin(prepare_admin_user) }

      # API 0.10.82 encoding: queued = done false + 0 runs; running = done false + runs > 0; applied = done true
      # (the row is kept 14 days on the server); failed = done false + error_messages.
      it 'shows the state of each SQL batch row in words, and keeps the flag of the other rows' do
        rows = [{ 'id' => 1, 'batch_sql' => true, 'done' => false, 'process_runs' => 0 },
                { 'id' => 2, 'batch_sql' => true, 'done' => false, 'process_runs' => 1 },
                { 'id' => 3, 'batch_sql' => true, 'done' => true, 'process_runs' => 1 },
                { 'id' => 4, 'batch_sql' => true, 'done' => false, 'process_runs' => 1, 'error_messages' => 'ERROR 1062' },
                micro_row.as_json]
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: rows.to_json))
        get(api_import_queues_path)
        cells = response.parsed_body.css('table.datagrid-table tbody td[data-column="state_flag"]')
        states = cells.first(4).map { |cell| cell.at_css('[data-batch-state]')&.[]('data-batch-state') }
        expect(states).to eq(%w[queued running applied failed])
        expect(cells[2].at_css('[data-batch-state]').text.strip).to eq(I18n.t('grids.import_queues.batch_states.applied'))
        expect(cells[2].at_css('[data-batch-state]')['title']).to eq(I18n.t('grids.import_queues.batch_states.applied_tooltip'))
        expect(cells[4].at_css('[data-batch-state]')).to be_nil
        expect(cells[4].text.strip).to eq(GogglesDb::ImportQueueDecorator.new(micro_row).state_flag.to_s)
      end
    end

    it_behaves_like('an API grid index showing an API error in place', 'import_queues') do
      let(:index_path) { api_import_queues_path }
      let(:api_params) { { page: anything, per_page: anything } }
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'PUT api_import_queue (update)' do
    let(:fixture_row) { FactoryBot.create(:import_queue) }
    let(:new_request_data) do
      {
        target_entity: 'Swimmer',
        swimmer: { id: 0, complete_name: '(Never mind: this will not get processed)' }
      }.to_json
    end

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        put(api_import_queue_path(fixture_row.id), params: { request_data: new_request_data })
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :put, url: "import_queue/#{fixture_row.id}", jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: 'true'))
        put(api_import_queue_path(fixture_row.id), params: { request_data: new_request_data })
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to eq(I18n.t('datagrid.edit_modal.edit_ok'))
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_import_queues_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'POST api_import_queues (create)' do
    let(:new_attributes) { FactoryBot.build(:import_queue).attributes }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        post(api_import_queues_path, params: new_attributes)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
        # API double:
        allow(APIProxy).to receive(:call)
          .with(
            method: :post, url: 'import_queue', jwt: admin_user.jwt,
            payload: anything
          ).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 0 } }.to_json))
        post(api_import_queues_path, params: new_attributes)
      end

      it 'sets the flash success message' do
        expect(flash[:info]).to be_present
        # (Can't really say which ID will be randomly generated by the WebMock)
      end

      it 'does NOT set the flash error message' do
        expect(flash[:error]).to be_nil
      end

      it 'redirects to /index' do
        expect(response).to redirect_to(api_import_queues_path)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'DELETE api_import_queues (destroy)' do
    let(:fixture_row) { FactoryBot.create(:import_queue) }

    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        delete(api_import_queues_destroy_path(id: fixture_row.id))
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      context 'when destroying a single row,' do
        before(:each) do
          admin_user = prepare_admin_user
          sign_in_admin(admin_user)
          # API double:
          allow(APIProxy).to receive(:call)
            .with(
              method: :delete, url: "import_queue/#{fixture_row.id}", jwt: admin_user.jwt
            ).and_return(DummyResponse.new(body: 'true'))
          delete(api_import_queues_destroy_path(id: fixture_row.id))
        end

        it 'sets the flash success message' do
          expect(flash[:info]).to eq(I18n.t('dashboard.grid_commands.delete_ok', tot: 1, ids: [fixture_row.id.to_s]))
        end

        it 'does NOT set the flash error message' do
          expect(flash[:error]).to be_nil
        end

        it 'redirects to /index' do
          expect(response).to redirect_to(api_import_queues_path)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
