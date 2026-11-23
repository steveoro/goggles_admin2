# frozen_string_literal: true

require 'rails_helper'

# Remote-write log (/remote_writes) with the DB sync card (last stored verdict) and its "Acknowledge" button.
RSpec.describe 'Remote writes' do
  let(:api_url) { APIProxy.configured_base_url.to_s.delete_suffix('/') }

  before(:each) do
    allow(APIProxy).to receive(:ping).and_return(DummyResponse.new(body: { msg: 'OK', version: '7.0' }.to_json))
    sign_in_admin(prepare_admin_user)
  end

  after(:each) { Ops::Database.reset_state! }

  it 'lists the logged writes, shows the stored DB sync verdict and acknowledges the writes (a new check is queued)' do
    FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
    FactoryBot.create(:ops_remote_write, base_url: api_url, endpoint: 'meeting/77', created_at: 1.minute.ago)

    visit(remote_writes_path)
    expect(page).to have_css('.app-sidebar a.nav-link.active[href="/remote_writes"]')
    expect(page).to have_css('table.datagrid-table td[data-column="endpoint"]', text: 'meeting/77')
    expect(page).to have_css('#remote-writes-db-sync #drift-indicator[data-drift-verdict="amber"]')
    expect(page).to have_css('turbo-frame#shell-status #status-pill-db_sync[data-status-level="warn"]')

    accept_confirm { click_button('btn-acknowledge') }
    expect(page).to have_text(I18n.t('remote_writes.acknowledge.done'))
    expect(Ops::RemoteWrite.acknowledged_at).to be_present
    expect_no_js_errors
  end
end
