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
        expect { post(federnuoto_watch_check_path, headers: { 'HTTP_REFERER' => sources_crawler_url }) }
          .to have_enqueued_job(FedernuotoWatchJob).with(manual: true)
        expect(response).to redirect_to(sources_crawler_url)
        expect(flash[:info]).to eq(I18n.t('federnuoto_watch.check.started'))
      end
    end

    describe 'POST /federnuoto_watch/acknowledge' do
      before(:each) do
        store.update { { 'digest' => 'new', 'rows' => [], 'change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k' }] } } }
      end

      it 'clears the pending change, removes the alert from every tab and logs the operator dismiss' do
        expect { post(federnuoto_watch_acknowledge_path) }
          .to have_broadcasted_to(AppNotificationsChannel::STREAM).with(dom_id: FedernuotoWatch::ALERT_DOM_ID, html: '')
        expect(response).to have_http_status(:no_content)
        expect(store.pending_change).to be_nil
        expect(store.read['ack_digest']).to eq('new')
        event = Ops::Event.where(kind: 'fin.watch_acknowledged').last
        expect(event).to have_attributes(actor: 'operator', subject_key: 'new')
        expect(event.data).to include('actor' => 'operator', 'reason' => 'operator', 'added' => 1)
        expect(Ops::Event.where(kind: 'fin.calendar_notice')).to be_empty
      end

      it 'acknowledges nothing when a newer snapshot landed since the alert was shown (its digest)' do
        post(federnuoto_watch_acknowledge_path, params: { digest: 'older' })
        expect(response).to have_http_status(:no_content)
        expect(store.pending_change).to be_present
        post(federnuoto_watch_acknowledge_path, params: { digest: 'new' })
        expect(store.pending_change).to be_nil
      end
    end

    describe 'POST /federnuoto_watch/dismiss_notice (0.10.103)' do
      let!(:notice) do
        Ops.record_event!(kind: 'fin.calendar_notice', actor: 'job', subject_type: 'fin_watch', subject_key: 'd',
                          data: { 'removed' => [{ 'name' => 'Gone meeting' }], 'without_link' => [], 'text_only' => false })
      end

      it 'dismisses the notice (its inbox item goes) and redirects back' do
        post(federnuoto_watch_dismiss_notice_path, params: { id: notice.id }, headers: { 'HTTP_REFERER' => root_url })
        expect(response).to redirect_to(root_url)
        expect(flash[:info]).to eq(I18n.t('federnuoto_watch.notice.dismissed'))
        expect(Inbox::Sources::FINNotice.dismissed_ids).to include(notice.id)
      end

      it 'refuses an unknown notice' do
        post(federnuoto_watch_dismiss_notice_path, params: { id: notice.id + 100 })
        expect(flash[:warning]).to eq(I18n.t('federnuoto_watch.notice.not_dismissed'))
        expect(Inbox::Sources::FINNotice.dismissed_ids).to be_empty
      end
    end

    it 'has no pull_calendar route any more (0.10.103: the calendar is crawled from Sources or by the automation)' do
      expect(Rails.application.routes.url_helpers).not_to respond_to(:federnuoto_watch_pull_calendar_path)
    end

    describe 'layout rendering' do
      it 'shows the pending change alert on any page' do
        store.update { { 'change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k', 'name' => 'Brand new meeting' }] } } }
        get(sources_crawler_path(sub_menu_type: 'Riepilogo Eventi'))
        expect(response.body).to include(FedernuotoWatch::ALERT_DOM_ID, 'Brand new meeting')
        expect(response.body).to include('<option selected="selected" value="Riepilogo Eventi">')
      end

      it 'does not show the alert when there is no pending change' do
        get(sources_crawler_path)
        expect(response.body).not_to include(%(id="#{FedernuotoWatch::ALERT_DOM_ID}"))
      end
    end
  end
end
