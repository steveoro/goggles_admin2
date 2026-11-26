# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# 0.10.103: the FIN change alert tells what the automation is doing, its dismiss posts the digest of the snapshot shown,
# and a change with nothing to crawl is a dismissible "Needs you" notice instead of an alert.
RSpec.describe 'FIN change alert' do
  let(:admin_user) { prepare_admin_user }
  let(:data_dir) { Pathname.new(Dir.mktmpdir('fin-alert-system')) }
  let(:store) { FedernuotoWatch::StateStore.new }
  let(:change) { { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'k-1', 'name' => 'Trofeo Nuovo', 'url' => '' }] } }

  before(:each) do
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(data_dir)
    FileUtils.rm_f([store.path, SeasonBoard::ActivityLog.default_path])
    store.update { { 'digest' => 'd2', 'ack_digest' => 'd1', 'rows' => [], 'last_checked' => Time.current.iso8601, 'change' => change } }
    sign_in_through_form(admin_user)
  end

  after(:each) do
    FileUtils.remove_entry(data_dir)
    FileUtils.rm_f([store.path, SeasonBoard::ActivityLog.default_path])
  end

  it 'shows the progress of the automation and, dismissed, acknowledges the snapshot it showed' do
    FedernuotoWatch::Progress.store!('digest' => 'd2', 'automation' => true, 'actionable' => 1, 'at_parity' => 0, 'calendar' => 'running',
                                     'pending' => [{ 'name' => 'Trofeo Nuovo', 'reason' => 'crawling' }])
    visit(sources_crawler_path)
    within("##{FedernuotoWatch::ALERT_DOM_ID}") do
      expect(page).to have_css('.federnuoto-watch-progress[data-fin-watch-progress="auto"]',
                               text: I18n.t('federnuoto_watch.alert.progress.calendar_running'))
      expect(page).to have_text(I18n.t('federnuoto_watch.alert.progress.busy.crawling', count: 1))
      click_button(I18n.t('federnuoto_watch.alert.dismiss'))
    end
    expect(page).to have_no_css("##{FedernuotoWatch::ALERT_DOM_ID}")
    # (the acknowledge is a background fetch: wait for it)
    Timeout.timeout(Capybara.default_max_wait_time) { sleep(0.1) while store.pending_change }
    expect(store.read['ack_digest']).to eq('d2')
    expect_no_js_errors
  end

  it 'shows no alert while the automation found nothing actionable, and the notice of a change with nothing to crawl' do
    FedernuotoWatch::Progress.store!('digest' => 'd2', 'automation' => true, 'actionable' => 0, 'checked_at' => Time.current.iso8601)
    notice = Ops.record_event!(kind: 'fin.calendar_notice', actor: 'job', subject_type: 'fin_watch', subject_key: 'd1',
                               data: { 'removed' => [{ 'name' => 'Meeting cancellato' }], 'without_link' => [], 'text_only' => false })
    visit(root_path)
    expect(page).to have_css("#dashboard-needs-you [data-inbox-key='fin_notice:#{notice.id}']")
    expect(page).to have_no_css("##{FedernuotoWatch::ALERT_DOM_ID}")
    within("#dashboard-needs-you [data-inbox-key='fin_notice:#{notice.id}']") do
      expect(page).to have_text('Meeting cancellato')
      click_button(I18n.t('inbox.fin_notice.dismiss'))
    end
    expect(page).to have_no_css("[data-inbox-key='fin_notice:#{notice.id}']")
    expect(Inbox::Sources::FINNotice.dismissed_ids).to include(notice.id)
    expect_no_js_errors
  end
end
