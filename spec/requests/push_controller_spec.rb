# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PushController do
  describe 'GET /index' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get '/push/index'
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user' do
      include AdminSignInHelpers

      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
      end

      it 'returns http success' do
        get '/push/index'
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'folder handling' do
    include AdminSignInHelpers

    let(:dirnames) { %w[data/results.new/212 data/results.new/242] }

    before(:each) do
      sign_in_admin(prepare_admin_user)
    end

    context 'when choosing the default folder (GET /index)' do
      before(:each) do
        allow(Rails.root).to receive(:glob).and_call_original
        allow(Rails.root).to receive(:glob).with('crawler/data/results.new/*')
                                           .and_return(dirnames.map { |dir| Rails.root.join('crawler', dir) })
        allow(SeasonDefaults).to receive(:default_season_id).and_return(242)
      end

      it 'opens the default season folder, or the requested one when listed' do
        get '/push/index'
        expect(response.body).to include('<option selected="selected" value="data/results.new/242">')

        get '/push/index', params: { curr_dir: 'data/results.new/212' }
        expect(response.body).to include('<option selected="selected" value="data/results.new/212">')
      end
    end

    describe 'POST /upload' do
      let(:sql_files) do
        %w[a/0001-a.sql b/0002-b.sql].map { |name| Rails.root.join('crawler/data/results.new/242', name) }
      end

      before(:each) do
        allow(Rails.root).to receive(:glob).and_call_original
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: { new: { id: 1 } }.to_json))
        allow(File).to receive(:open).and_call_original
        allow(File).to receive(:rename)
        allow(FileUtils).to receive(:mkdir_p)
      end

      it 'pushes exactly the recursive, sorted listing for a *.sql glob and keeps the folder in the redirect' do
        allow(Rails.root).to receive(:glob).with('crawler/data/results.new/242/**/*.sql').and_return(sql_files.reverse)
        allow(File).to receive(:open).with(anything) { StringIO.new('') }
        pushed = []
        allow(APIProxy).to receive(:call) do |**opts|
          pushed << opts
          DummyResponse.new(body: { new: { id: 1 } }.to_json)
        end

        post '/push/upload', params: { file_path: 'data/results.new/242/*.sql' }

        expect(pushed.size).to eq(2)
        expect(File).to have_received(:rename).with(sql_files.first, anything).ordered
        expect(response).to redirect_to(push_index_path(parent_folder: 'results.new', curr_dir: 'data/results.new/242'))
      end

      it 'records one push.uploaded event per pushed file' do
        allow(Rails.root).to receive(:glob).with('crawler/data/results.new/242/**/*.sql').and_return(sql_files)
        allow(File).to receive(:open).with(anything) { StringIO.new('') }

        expect { post '/push/upload', params: { file_path: 'data/results.new/242/*.sql' } }
          .to change(Ops::Event, :count).by(2)

        events = Ops::Event.of_kind('push.uploaded').order(:id).to_a
        expect(events.map(&:subject_key)).to eq(%w[data/results.new/242/a/0001-a.sql data/results.new/242/b/0002-b.sql])
        expect(events.first.actor).to eq('operator')
        expect(events.first.data).to include('file' => '0001-a.sql', 'import_queue_id' => 1)
      end

      it 'records a push.failed event with the remote error message' do
        allow(File).to receive(:open).with(anything) { StringIO.new('') }
        allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: { msg: 'bad SQL' }.to_json))

        expect { post '/push/upload', params: { file_path: 'data/results.new/242/a/0001-a.sql' } }
          .to change(Ops::Event, :count).by(1)

        event = Ops::Event.of_kind('push.failed').first
        expect(event.level).to eq('error')
        expect(event.data).to include('error' => 'bad SQL')
        expect(flash[:error]).to eq('bad SQL')
      end

      it 'is not affected by a failing ops write' do
        allow(File).to receive(:open).with(anything) { StringIO.new('') }
        allow(Ops).to receive(:record_event!).and_raise(StandardError, 'ops down')

        post '/push/upload', params: { file_path: 'data/results.new/242/a/0001-a.sql' }

        expect(response).to redirect_to(push_index_path(parent_folder: 'results.new', curr_dir: 'data/results.new/242'))
        expect(flash[:info]).to be_present
        expect(flash[:error]).to be_blank
      end

      it 'refuses any path outside crawler/data' do
        ['/etc/passwd', 'data/../../config/*.sql', Rails.root.join('config/database.yml').to_s].each do |bad_path|
          post '/push/upload', params: { file_path: bad_path }

          expect(response).to redirect_to(push_index_path)
          expect(flash[:warning]).to be_present
        end
        expect(APIProxy).not_to have_received(:call)
      end
    end
  end
end
