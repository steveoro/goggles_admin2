# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RemoteWritesController do
  include AdminSignInHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { prepare_admin_user }
  let(:api_url) { APIProxy.configured_base_url.to_s.delete_suffix('/') }
  let(:page_body) { response.parsed_body }

  after(:each) { Ops::Database.reset_state! }

  context 'with an unlogged user' do
    it 'is a redirect to the login path' do
      get(remote_writes_path)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with a logged-in user' do
    before(:each) do
      sign_in_admin(admin_user)
      allow(APIProxy).to receive(:call).and_raise('no API call expected')
    end

    it 'lists the remote writes, newest first, with keys only and the DB sync card, without any API call' do
      FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
      FactoryBot.create(:ops_remote_write, endpoint: 'meeting/77', base_url: api_url, payload_keys: %w[description],
                                           created_at: 1.hour.ago)
      FactoryBot.create(:ops_remote_write, endpoint: 'team/88', base_url: api_url, status_code: 422,
                                           error_detail: 'Invalid name')
      get(remote_writes_path)
      expect(response).to have_http_status(:success)
      rows = page_body.css('table.datagrid-table tbody tr')
      expect(rows.map { |row| row.at_css('td[data-column="endpoint"]').text.strip }).to eq(%w[team/88 meeting/77])
      expect(rows.first.at_css('td[data-column="status"] .badge').text).to eq(I18n.t('remote_writes.statuses.failed'))
      expect(page_body.at_css('#remote-writes-db-sync #drift-indicator')['data-drift-verdict']).to eq('amber') # (last stored check)
      expect(page_body.at_css('#btn-open-db-sync')['href']).to eq(db_sync_path)
      expect(page_body.at_css('#btn-acknowledge')).to be_present
      expect(page_body.at_css('.app-page-count').text).to include('2')
    end

    it 'filters by endpoint and outcome' do
      FactoryBot.create(:ops_remote_write, endpoint: 'meeting/77', base_url: api_url)
      FactoryBot.create(:ops_remote_write, endpoint: 'team/88', base_url: api_url, status_code: 503, unreachable: true)
      get(remote_writes_path, params: { remote_writes_grid: { endpoint: 'team' } })
      expect(page_body.css('td[data-column="endpoint"]').map { |td| td.text.strip }).to eq(%w[team/88])
      get(remote_writes_path, params: { remote_writes_grid: { status: 'success' } })
      expect(response.parsed_body.css('td[data-column="endpoint"]').map { |td| td.text.strip }).to eq(%w[meeting/77])
    end

    it 'exports the filtered rows as CSV' do
      FactoryBot.create(:ops_remote_write, endpoint: 'meeting/77', base_url: api_url)
      get(remote_writes_path(format: :csv))
      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('text/csv')
      expect(response.body).to include('meeting/77')
    end

    it 'renders a notice instead of the grid with the ops DB missing' do
      allow(Ops::Database).to receive(:state).and_return(:missing)
      get(remote_writes_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#remote-writes-unavailable')).to be_present
      expect(page_body.at_css('#data-grid')).to be_nil
      expect(page_body.at_css('#btn-acknowledge')).to be_nil
    end

    describe 'POST acknowledge' do
      it 'stores drift.acknowledged_at, so that the DB sync check no longer counts the older writes, and queues a check' do
        FactoryBot.create(:ops_remote_write, base_url: api_url)
        travel(1.second) do
          expect { post(remote_writes_acknowledge_path) }.to have_enqueued_job(DriftCheckJob).with(trigger: 'manual')
        end
        expect(response).to redirect_to(remote_writes_path)
        expect(flash[:info]).to eq(I18n.t('remote_writes.acknowledge.done'))
        expect(Ops::RemoteWrite.acknowledged_at).to be_present
        expect(Ops::RemoteWrite.unacknowledged(api_url)).to be_empty
      end

      it 'reports a failure with the ops DB missing' do
        allow(Ops::Database).to receive(:state).and_return(:missing)
        post(remote_writes_acknowledge_path)
        expect(flash[:error]).to eq(I18n.t('remote_writes.acknowledge.failed'))
      end
    end
  end

  context 'with an API-offline session' do
    before(:each) do
      sign_in_api_offline(admin_user)
      allow(APIProxy).to receive(:call).with(hash_excluding(url: 'session')).and_raise('no API call expected')
    end

    it 'renders the page (no redirect to Settings)' do
      get(remote_writes_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#remote-writes-db-sync #drift-indicator')['data-drift-verdict']).to eq('unknown')
    end
  end

  # The hook itself is in APIProxy (spec/strategies/api_proxy_spec.rb); this checks the request attributes.
  context 'when an admin edits a row through an api_* grid (real APIProxy call, WebMock)' do
    before(:each) { sign_in_admin(admin_user) }

    it 'logs the write with the controller#action source and the user ID' do
      user_row = GogglesDb::User.first
      expect { put(api_user_path(user_row.id), params: { id: user_row.id, description: 'SECRET-VALUE' }) }
        .to change(Ops::RemoteWrite, :count).by(1)
      row = Ops::RemoteWrite.last
      expect(row).to have_attributes(http_method: 'put', endpoint: "user/#{user_row.id}", source: 'api_users#update',
                                     user_id: admin_user.id, status_code: 200)
      expect(row.payload_keys).to include('id', 'description')
      expect(row.attributes.to_json).not_to include('SECRET-VALUE')
    end
  end
end
