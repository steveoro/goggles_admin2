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

    it 'renders only the status frame with one pill per probe needing attention, without any API or crawler call' do
      get(shell_status_path)
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.at('html body .app-shell')).to be_nil
      # No snapshot yet: the snapshot probes are unknown (one pill each), the others fold into the "N OK" pill.
      singles = frame.css('.app-status-pill:not(#status-pill-all)')
      ok_count = frame.at_css('#status-pill-all')&.[]('data-ok-count').to_i
      expect(singles.pluck('id')).to include('status-pill-api', 'status-pill-db_sync')
      expect(singles.pluck('data-status-level')).to all(satisfy { |level| level != 'ok' })
      expect(singles.size + ok_count).to eq(SystemStatus::Registry::PROBES.size)
      expect(APIProxy).not_to have_received(:call)
      expect(APIProxy).not_to have_received(:ping)
      expect(CrawlerClient).not_to have_received(:new)
    end

    it 'renders a single "All OK" pill, listing every probe, when they are all OK' do
      results = SystemStatus::Registry::PROBES.map do |name|
        key = name.demodulize.delete_suffix('Probe').underscore.to_sym
        SystemStatus::Result.new(key:, label: name.demodulize, level: :ok, detail: 'fine')
      end
      allow(SystemStatus::Registry).to receive(:results).and_return(results)
      get(shell_status_path)
      expect(frame.css('.app-status-pill').pluck('id')).to eq(['status-pill-all'])
      expect(frame.at_css('a#status-pill-all')['href']).to eq(root_path(anchor: 'dashboard-system'))
      expect(frame.at_css('#status-pill-all')['data-bs-title'].split("\n").size).to eq(results.size + 1)
    end

    it 'enqueues a refresh when a snapshot is missing or stale' do
      expect { get(shell_status_path) }.to have_enqueued_job(SystemStatus::RefreshJob).on_queue('default')
    end

    it 'does not enqueue a refresh while the snapshots are fresh' do
      url = APIProxy.configured_base_url.delete_suffix('/')
      Ops::Snapshot.write!("api.status:#{url}", { 'reachable' => true, 'code' => 200, 'version' => '7.2' })
      Ops::Snapshot.write!('system_status.crawler', { 'reachable' => false })
      FactoryBot.create(:ops_db_fingerprint, api_base_url: url)
      expect { get(shell_status_path) }.not_to have_enqueued_job(SystemStatus::RefreshJob)
      # The API is OK: no pill of its own, it is listed in the summary pill.
      expect(frame.at_css('#status-pill-api')).to be_nil
      expect(frame.at_css('#status-pill-all')['data-bs-title']).to match(/^API: .+\(v\. 7\.2\)$/)
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

    it 'renders (no redirect to Settings) with the API pill unknown (linking to Settings), without any API call' do
      get(shell_status_path)
      expect(response).to have_http_status(:success)
      expect(frame.at_css('#status-pill-api')['data-status-level']).to eq('unknown')
      expect(frame.at_css('a#status-pill-api')['href']).to eq(settings_path)
      expect(APIProxy).not_to have_received(:call).with(hash_excluding(url: 'session'))
      expect(APIProxy).not_to have_received(:ping)
    end
  end
end
