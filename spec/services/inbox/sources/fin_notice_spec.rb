# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

# 0.10.103: the FIN calendar changes acknowledged with nothing to crawl, shown until dismissed.
RSpec.describe Inbox::Sources::FINNotice do
  include InboxSummaryFixtures

  let(:now) { Time.current }
  let(:context) { inbox_context(now:) }

  def notice(data, occurred_at: 1.hour.ago)
    Ops.record_event!(kind: 'fin.calendar_notice', actor: 'job', subject_type: 'fin_watch', subject_key: 'd', data:).tap do |event|
      event.update_columns(occurred_at:) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  it 'has the :fin_notice key, needs the ops DB and emits nothing without notices' do
    expect(described_class.key).to eq(:fin_notice)
    expect(described_class.enabled?(context)).to be true
    expect(described_class.enabled?(inbox_context(ops_available: false))).to be false
    expect(described_class.new.items(context)).to eq([])
  end

  it 'emits one notice item per notice event, with Dismiss (POST) and a link to the board' do
    event = notice({ 'removed' => [{ 'name' => 'Gone meeting' }], 'without_link' => [{ 'name' => 'No link yet' }, { 'name' => 'Another' }],
                     'text_only' => false })
    item = described_class.new.items(context).first
    expect(item).to have_attributes(key: "fin_notice:#{event.id}", band: :notice, kind: :fin_notice)
    expect(item.title).to eq(I18n.t('inbox.fin_notice.title', parts: [I18n.t('inbox.fin_notice.removed', count: 1),
                                                                      I18n.t('inbox.fin_notice.without_link', count: 2)].join(', ')))
    expect(item.detail).to eq(I18n.t('inbox.fin_notice.detail', names: 'Gone meeting, No link yet, Another'))
    expect(item.action).to have_attributes(path: '/federnuoto_watch/dismiss_notice', http_method: :post, params: { id: event.id })
    expect(item.secondary_action.path).to eq('/season_board')
    expect(item.since.to_i).to eq(event.occurred_at.to_i)
  end

  it 'tells a text-only change' do
    notice({ 'removed' => [], 'without_link' => [], 'text_only' => true })
    item = described_class.new.items(context).first
    expect(item.title).to eq(I18n.t('inbox.fin_notice.title', parts: I18n.t('inbox.fin_notice.text_only')))
    expect(item.detail).to eq(I18n.t('inbox.fin_notice.detail_text_only'))
  end

  it 'hides a dismissed notice only, and the notices older than the window' do
    first = notice({ 'removed' => [{ 'name' => 'A' }] })
    second = notice({ 'removed' => [{ 'name' => 'B' }] })
    notice({ 'removed' => [{ 'name' => 'Old' }] }, occurred_at: 40.days.ago)
    expect(described_class.dismiss!(first.id)).to be true
    expect(described_class.new.items(context).map(&:key)).to eq(["fin_notice:#{second.id}"])
  end

  it 'refuses to dismiss an unknown event or another kind of event' do
    other = Ops.record_event!(kind: 'fin.watch_changed', actor: 'job')
    expect(described_class.dismiss!(other.id)).to be false
    expect(described_class.dismiss!('x')).to be false
    expect(described_class.dismissed_ids).to be_empty
  end

  it 'shows at most MAX_ITEMS notices, newest first' do
    (described_class::MAX_ITEMS + 2).times { |idx| notice({ 'removed' => [{ 'name' => "M#{idx}" }] }, occurred_at: (10 - idx).minutes.ago) }
    expect(described_class.new.items(context).size).to eq(described_class::MAX_ITEMS)
  end
end
