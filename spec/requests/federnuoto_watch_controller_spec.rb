# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatchController do
  let(:store) { FedernuotoWatch::StateStore.new }

  after(:each) { FileUtils.rm_f(store.path) }

  context 'with an unlogged user' do
    it 'POST /check is a redirect to the login path' do
      post(federnuoto_watch_check_path)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  context 'with a logged-in user' do
    include AdminSignInHelpers

    before(:each) do
      admin_user = prepare_admin_user
      sign_in_admin(admin_user)
    end

    describe 'POST /federnuoto_watch/check' do
      it 'enqueues a manual check and redirects back' do
        expect { post(federnuoto_watch_check_path, headers: { 'HTTP_REFERER' => pull_index_url }) }
          .to have_enqueued_job(FedernuotoWatchJob).with(manual: true)
        expect(response).to redirect_to(pull_index_url)
        expect(flash[:info]).to eq(I18n.t('federnuoto_watch.check.started'))
      end
    end

    describe 'POST /federnuoto_watch/acknowledge' do
      before(:each) do
        store.update { { 'digest' => 'new', 'rows' => [], 'change' => { 'detected_at' => Time.current.iso8601 } } }
      end

      it 'clears the pending change' do
        post(federnuoto_watch_acknowledge_path)
        expect(response).to have_http_status(:no_content)
        expect(store.pending_change).to be_nil
        expect(store.read['ack_digest']).to eq('new')
      end
    end

    describe 'POST /federnuoto_watch/pull_calendar' do
      let(:launcher) { instance_double(CrawlerLauncher) }

      before(:each) { allow(CrawlerLauncher).to receive(:new).and_return(launcher) }

      it 'starts the crawler if needed and opens the Pull page with the sub-menu preset' do
        allow(launcher).to receive(:ensure_running!).and_return(:started)
        post(federnuoto_watch_pull_calendar_path)
        expect(response).to redirect_to(pull_index_path(sub_menu_type: 'Riepilogo Eventi'))
        expect(flash[:info]).to eq(I18n.t('federnuoto_watch.crawler.started'))
      end

      it 'sets an error flash when the crawler cannot be started' do
        allow(launcher).to receive(:ensure_running!).and_return(:failed)
        post(federnuoto_watch_pull_calendar_path)
        expect(flash[:error]).to be_present
      end
    end

    describe 'layout rendering' do
      it 'shows the pending change alert on any page' do
        store.update { { 'change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k', 'name' => 'Brand new meeting' }] } } }
        get(pull_index_path(sub_menu_type: 'Riepilogo Eventi'))
        expect(response.body).to include(FedernuotoWatch::ALERT_DOM_ID, 'Brand new meeting')
        expect(response.body).to include('<option selected="selected" value="Riepilogo Eventi">')
      end

      it 'does not show the alert when there is no pending change' do
        get(pull_index_path)
        expect(response.body).not_to include(%(id="#{FedernuotoWatch::ALERT_DOM_ID}"))
      end
    end
  end
end
