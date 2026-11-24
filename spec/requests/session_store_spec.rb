# frozen_string_literal: true

require 'rails_helper'

# Phase 14, step 1: the web sessions live in the ops DB (Ops::SessionStoreSetup), so that a guided restore of the
# MySQL primary (which replaces its 'sessions' table) keeps the operator signed in.
RSpec.describe 'Session store on the ops DB' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:login_params) { { user: { email: admin_user.email, password: 'Password123!' } } }

  before(:each) do
    allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: []))
  end

  after(:each) { Ops::Database.reset_state! }

  def ops_session_ids
    Ops::ApplicationRecord.with_connection { |conn| conn.select_values('SELECT session_id FROM sessions') }
  end

  def mysql_session_count
    ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM sessions').to_i
  end

  it 'installs the router as the session class' do
    expect(ActionDispatch::Session::ActiveRecordStore.session_class).to eq(Ops::SessionStoreSetup::Router)
    expect(Ops::SessionStoreSetup::Router.session_class).to eq(Ops::SessionStoreSetup::OpsSession)
  end

  it 'writes the session of a sign-in to the ops DB, not to MySQL' do
    mysql_before = mysql_session_count
    post(user_session_path, params: login_params)
    expect(response).to redirect_to(root_path)
    expect(ops_session_ids.size).to eq(1)
    expect(mysql_session_count).to eq(mysql_before)
    timestamps = Ops::ApplicationRecord.with_connection { |conn| conn.select_one('SELECT created_at, updated_at FROM sessions') }
    expect(timestamps.values).to all(be_present)
  end

  it 'keeps the operator signed in after the MySQL sessions table is emptied (as a restore does)' do
    post(user_session_path, params: login_params)
    ActiveRecord::Base.connection.execute('DELETE FROM sessions')
    get(root_path)
    expect(response).to have_http_status(:success)
  end

  it 'keeps an API-offline sign-in (session[:api_offline]) in the ops DB' do
    sign_in_api_offline(admin_user)
    expect(session[:api_offline]).to be_present
    expect(ops_session_ids.size).to eq(1)
    get(settings_path)
    expect(response).to have_http_status(:success)
  end

  it 'deletes the ops row on sign-out (a new, empty session replaces it)' do
    post(user_session_path, params: login_params)
    signed_in_ids = ops_session_ids
    delete(destroy_user_session_path)
    expect(ops_session_ids & signed_in_ids).to be_empty
    get(root_path)
    expect(response).to redirect_to(new_user_session_path)
  end

  it 'falls back to the MySQL sessions table while the ops DB is not ready' do
    allow(Ops::Database).to receive(:state).and_return(:needs_migration)
    expect(Ops::SessionStoreSetup::Router.session_class).to eq(ActiveRecord::SessionStore::Session)
    mysql_before = mysql_session_count
    post(user_session_path, params: login_params)
    expect(response).to redirect_to(root_path)
    expect(mysql_session_count).to eq(mysql_before + 1)
  end

  describe Ops::SessionStoreSetup do
    include ActiveSupport::Testing::TimeHelpers

    it 'counts and trims the ops rows' do
      post(user_session_path, params: login_params)
      expect(described_class.count).to eq(1)
      expect(described_class.trim!(older_than: 1.day)).to eq(0)
      travel_to(2.days.from_now) { expect(described_class.trim!(older_than: 1.day)).to eq(1) }
      expect(described_class.count).to eq(0)
    end
  end
end
