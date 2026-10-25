# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PullController do
  describe 'GET /index' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get '/pull/index'
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
      end

      it 'returns http success and exposes the FICR crawler target' do
        get '/pull/index'
        expect(response).to have_http_status(:success)
        expect(response.body).to include('FICR results')
      end
    end
  end

  describe 'POST /run_crawler_api' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
      allow(RestClient::Request).to receive(:execute).and_return(double(body: '{}'))
    end

    it 'routes a layout-2 direct FIN URL to /pull_results with meeting_url' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 2,
        target_url: 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/123',
        sub_menu_type: 'Eventi',
        target_event: ''
      }

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(
          url: 'http://localhost:7000/pull_results',
          headers: hash_including(
            'params' => hash_including(
              'season_id' => '242',
              'layout' => 2,
              'meeting_url' => 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/123'
            ),
            'Content-Type' => 'application/json'
          )
        )
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'routes a layout-4 URL to /pull_results_microplus' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 4,
        target_url: 'https://fin2025.microplustiming.com/MA_2025_06_24-29_Riccione.php',
        sub_menu_type: 'Eventi'
      }

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(url: 'http://localhost:7000/pull_results_microplus')
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'routes a layout-5 FICR URL to the dedicated FICR endpoint' do
      ficr_url = "https://nuoto.ficr.it/#/NUO/tempi/25'%20TROFEO%20ACSI%20CITTA'%20DI%20BRESCIA/2023/29/5/AAF/3"
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 5,
        target_url: ficr_url,
        sub_menu_type: 'Eventi',
        target_event: 'ignored for FICR'
      }

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(
          url: 'http://localhost:7000/pull_results_ficr',
          headers: hash_including(
            'params' => hash_including(
              'season_id' => '242',
              'layout' => 5,
              'meeting_url' => ficr_url
            ),
            'Content-Type' => 'application/json'
          )
        )
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'rejects a layout-2 request with the placeholder still in target_url' do
      post '/pull/run_crawler_api', params: {
        season_id: 242,
        layout_id: 2,
        target_url: 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/ (+<LINK>)',
        sub_menu_type: 'Eventi'
      }

      expect(RestClient::Request).not_to have_received(:execute)
      expect(response).to redirect_to(pull_index_path)
      expect(flash[:warning]).to be_present
    end
  end

  describe 'GET /pull/calendar_meetings' do
    include AdminSignInHelpers

    let(:csv_dir) { Rails.root.join('crawler/data/calendar.new/9999') }
    let(:csv_path) { File.join(csv_dir, 'test-cal.csv') }

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
      FileUtils.mkdir_p(csv_dir)
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv_path)
    end

    after(:each) { FileUtils.rm_rf(csv_dir) }

    it 'renders one row per CSV meeting with its state indicators' do
      get '/pull/calendar_meetings', params: { file_path: csv_path }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Distanze Speciali Campania')
      expect(response.body).to include('7° Trofeo Gonzaga - Memorial Rascaroli')
      # 10 CSV rows => 10 checkboxes (some disabled):
      expect(response.body.scan('selected_rows[]').size).to eq(10)
    end

    it 'marks a row as pending when its manifest sits in manifests/<season>' do
      pending_dir = Rails.root.join('crawler/data/manifests/9999')
      FileUtils.mkdir_p(pending_dir)
      File.write(pending_dir.join('manifest-2026-10-24-Distanze_Speciali_Campania.pdf'), 'x')

      get '/pull/calendar_meetings', params: { file_path: csv_path }
      expect(response.body).to include('fa-clock-o') # pending manifest icon

      FileUtils.rm_rf(pending_dir)
    end

    it 'redirects with a warning for files outside crawler/data' do
      get '/pull/calendar_meetings', params: { file_path: '/etc/passwd' }
      expect(response).to redirect_to(pull_calendar_files_path)
      expect(flash[:warning]).to be_present
    end
  end

  describe 'POST /pull/process_selected_meetings' do
    include AdminSignInHelpers

    let(:csv_dir) { Rails.root.join('crawler/data/calendar.new/9999') }
    let(:csv_path) { File.join(csv_dir, 'test-cal.csv') }

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
      FileUtils.mkdir_p(csv_dir)
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv_path)
      allow(RestClient::Request).to receive(:execute).and_return(double(body: '{}'))
    end

    after(:each) { FileUtils.rm_rf(csv_dir) }

    it 'writes a -sel- subset CSV and calls /pull_results on it' do
      post '/pull/process_selected_meetings', params: {
        file_path: csv_path, rows_count: 10, selected_rows: %w[0 4]
      }

      subset_file = Dir.glob(File.join(csv_dir, 'test-cal-sel-*.csv')).first
      expect(subset_file).to be_present
      subset_rows = CSV.read(subset_file, headers: true)
      expect(subset_rows.size).to eq(2)
      expect(subset_rows['name'])
        .to eq(['Distanze Speciali Campania', '7° Trofeo Gonzaga - Memorial Rascaroli'])

      expect(RestClient::Request).to have_received(:execute).with(
        hash_including(
          url: 'http://localhost:7000/pull_results',
          headers: hash_including(
            'params' => hash_including(
              'season_id' => 9999,
              'file_path' => subset_file,
              'layout' => 2
            )
          )
        )
      )
      expect(response).to redirect_to(pull_index_path)
    end

    it 'rejects an empty selection' do
      post '/pull/process_selected_meetings', params: { file_path: csv_path, rows_count: 10 }

      expect(RestClient::Request).not_to have_received(:execute)
      expect(response).to redirect_to(pull_calendar_meetings_path(file_path: csv_path))
      expect(flash[:warning]).to be_present
    end

    it 'rejects a stale rows_count (file changed under the page)' do
      post '/pull/process_selected_meetings', params: {
        file_path: csv_path, rows_count: 5, selected_rows: %w[0]
      }

      expect(RestClient::Request).not_to have_received(:execute)
      expect(flash[:warning]).to be_present
    end

    it 'rejects a file outside crawler/data' do
      post '/pull/process_selected_meetings', params: {
        file_path: '/tmp/anything.csv', rows_count: 1, selected_rows: %w[0]
      }

      expect(RestClient::Request).not_to have_received(:execute)
      expect(response).to redirect_to(pull_calendar_files_path)
    end
  end

  describe 'POST /pull/extract_manifests' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    let(:runner) do
      instance_double(PdfManifests::BatchRunner, preflight_error: nil, pdf_list: %w[a.pdf b.pdf],
                                                 start_in_thread!: instance_double(Thread))
    end

    it 'starts a background batch when preflight passes' do
      allow(PdfManifests::BatchRunner).to receive_messages(running?: false, new: runner)

      post '/pull/extract_manifests', params: { season_id: 9999 }

      expect(PdfManifests::BatchRunner).to have_received(:new).with(season_id: 9999)
      expect(runner).to have_received(:start_in_thread!)
      expect(flash[:info]).to be_present
      expect(response).to redirect_to(pull_index_path)
    end

    it 'refuses to start when a batch is already running' do
      allow(PdfManifests::BatchRunner).to receive(:running?).and_return(true)
      allow(PdfManifests::BatchRunner).to receive(:new)

      post '/pull/extract_manifests', params: { season_id: 9999 }

      expect(PdfManifests::BatchRunner).not_to have_received(:new)
      expect(flash[:warning]).to be_present
    end

    it 'reports the preflight blocker' do
      blocked = instance_double(PdfManifests::BatchRunner, preflight_error: :no_manifests)
      allow(PdfManifests::BatchRunner).to receive_messages(running?: false, new: blocked)

      post '/pull/extract_manifests', params: { season_id: 9999 }
      expect(flash[:warning]).to be_present
    end
  end

  describe 'GET /pull/extraction_status' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    it 'returns the JSON payload polled by the UI' do
      allow(PdfManifests::BatchRunner).to receive_messages(running?: false, read_status: { 'running' => false, 'extracted' => 3 })

      get '/pull/extraction_status', params: { season_id: 9999 }

      expect(response).to have_http_status(:success)
      payload = response.parsed_body
      expect(payload['running']).to be(false)
      expect(payload['status']['extracted']).to eq(3)
      expect(payload).to have_key('pending')
    end
  end
end
