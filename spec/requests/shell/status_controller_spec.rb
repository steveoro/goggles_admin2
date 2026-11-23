# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::StatusController do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:frame) { response.parsed_body.at_css('turbo-frame#shell-status') }

  before(:each) do
    allow(APIProxy).to receive(:ping)
    allow(CrawlerClient).to receive(:new)
  end

  after(:each) { Ops::Database.reset_state! }

  context 'with an unlogged user' do
    it 'is a redirect to the login path' do
      get(shell_status_path)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with a logged-in user' do
    before(:each) do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call)
    end

    it 'renders only the status frame with one pill per probe, without any API or crawler call' do
      get(shell_status_path)
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at('html body .app-shell')).to be_nil
      expect(frame.css('.app-status-pill').pluck('id')).to eq(%w[status-pill-api status-pill-crawler status-pill-queue
                                                                 status-pill-fin_watch])
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
      expect(CrawlerClient).not_to have_received(:new)
    end

    it 'enqueues a refresh when a snapshot is missing or stale' do
      expect { get(shell_status_path) }.to have_enqueued_job(SystemStatus::RefreshJob).on_queue('default')
    end

    it 'does not enqueue a refresh while the snapshots are fresh' do
      url = APIProxy.configured_base_url.delete_suffix('/')
      Ops::Snapshot.write!("api.status:#{url}", { 'reachable' => true, 'code' => 200, 'version' => '7.2' })
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => false })
      expect { get(shell_status_path) }.not_to have_enqueued_job(SystemStatus::RefreshJob)
      expect(frame.at_css('#status-pill-api')['data-status-level']).to eq('ok')
    end

    it 'does not enqueue a refresh with the ops DB missing, and still renders' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      expect { get(shell_status_path) }.not_to have_enqueued_job(SystemStatus::RefreshJob)
      expect(response).to have_http_status(:success)
      expect(frame.at_css('#status-pill-api')['data-status-level']).to eq('unknown')
    end
  end

  context 'with an API-offline session' do
    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive(:call).with(hash_excluding(url: 'session'))
    end

    it 'renders (no redirect to Settings) with the API pill in error, without any API call' do
      get(shell_status_path)
      expect(response).to have_http_status(:success)
      expect(frame.at_css('#status-pill-api')['data-status-level']).to eq('error')
      expect(APIProxy).not_to have_received(:call).with(hash_excluding(url: 'session'))
      expect(APIProxy).not_to have_received(:ping)
    end
  end
end
