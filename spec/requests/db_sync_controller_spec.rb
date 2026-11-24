# frozen_string_literal: true

require 'rails_helper'

# /db_sync reads only the ops DB rows: every example makes APIProxy raise.
RSpec.describe DbSyncController do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:api_url) { APIProxy.configured_base_url.to_s.delete_suffix('/') }
  let(:page_body) { response.parsed_body }

  after(:each) { Ops::Database.reset_state! }

  it 'is a redirect to the login path for an unlogged user' do
    get(db_sync_path)
    expect(response).to redirect_to(new_user_session_path)
  end

  context 'with a logged-in user' do
    before(:each) do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_raise('no API call expected')
      allow(APIProxy).to receive(:ping).and_raise('no API call expected')
    end

    it 'shows the last check: verdict, reasons, per-table comparison, remote writes and history' do
      FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 1.hour.ago)
      red = FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: api_url,
                                                         local: { 'tables' => { 'laps' => { 'count' => 10, 'max_id' => 100 } } },
                                                         remote: { 'tables' => { 'laps' => { 'count' => 12, 'max_id' => 120 } } })
      FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'meeting/77')
      get(db_sync_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#db-sync-verdict')['data-verdict']).to eq('red')
      expect(page_body.at_css('#db-sync-verdict #drift-indicator')['data-db-fingerprint-id']).to eq(red.id.to_s)
      expect(page_body.at_css('#db-sync-reasons li[data-reason-code="id_collision"]').text).to include('laps', '120')
      laps = page_body.at_css('#db-sync-table-laps')
      expect(laps['class']).to include('table-danger')
      expect(laps.text).to include('100', '120', '-20')
      expect(page_body.at_css('#db-sync-remote-writes').text).to include('meeting/77')
      expect(page_body.css('#db-sync-history tbody tr').size).to eq(2)
    end

    it 'is the Data quality > DB sync page, with "Check now"' do
      get(db_sync_path)
      expect(page_body.at_css('#btn-db-sync-check')).to be_present
      expect(page_body.at_css('.app-sidebar a.nav-link.active[href="/db_sync"]')).to be_present
    end

    it 'shows a past check by id, flagging it as older' do
      old = FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url, taken_at: 1.hour.ago)
      FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url)
      get(db_sync_path(id: old.id))
      expect(page_body.at_css('#db-sync-verdict')['data-verdict']).to eq('amber')
      expect(page_body.at_css('#db-sync-past-check')).to be_present
    end

    it 'explains a missing capability and the absence of checks' do
      get(db_sync_path)
      expect(page_body.at_css('#db-sync-never')).to be_present
      expect(page_body.at_css('#db-sync-no-capability').text).to eq(I18n.t('db_sync.capability_unknown'))
    end

    it 'renders only the live frame with frame=1' do
      FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url)
      get(db_sync_path(frame: 1))
      expect(response.body).to start_with('<turbo-frame')
      expect(page_body.at_css('turbo-frame#db-sync-frame #db-sync-verdict')).to be_present
      expect(page_body.at_css('.app-shell')).to be_nil
    end

    it 'queues a manual check on "Check now", the frame then polling until it is stored' do
      expect { post(db_sync_check_path) }.to have_enqueued_job(DriftCheckJob).with(trigger: 'manual')
      expect(response).to redirect_to(db_sync_path)
      get(db_sync_path)
      expect(page_body.at_css('#db-sync-pending')).to be_present
      expect(page_body.at_css('[data-outbox-busy="true"]')).to be_present
    end

    it 'acknowledges the remote writes and queues a check' do
      expect { post(db_sync_acknowledge_path) }.to have_enqueued_job(DriftCheckJob).with(trigger: 'manual')
      expect(Ops::RemoteWrite.acknowledged_at).to be_present
      expect(flash[:notice]).to eq(I18n.t('db_sync.flash.acknowledged'))
    end

    it 'renders a notice with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      get(db_sync_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#db-sync-ops-missing')).to be_present
      post(db_sync_check_path)
      expect(flash[:alert]).to eq(I18n.t('db_sync.flash.ops_missing'))
    end
  end

  context 'with an API-offline session' do
    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive(:call).with(hash_excluding(url: 'session')).and_raise('no API call expected')
    end

    it 'renders the page from the stored rows (no redirect to Settings)' do
      FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
      get(db_sync_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#db-sync-verdict')['data-verdict']).to eq('amber')
    end
  end
end
