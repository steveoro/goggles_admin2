# frozen_string_literal: true

require 'rails_helper'

# (The full state table, with real disk fixtures, is in builder_spec.rb)
RSpec.describe SeasonBoard::StateResolver do
  subject(:resolver) { described_class.new(today: Date.new(2026, 11, 12)) }

  let(:url) { 'https://www.federnuoto.it/x.html#/risultati/150091:a.html' }

  # links: calendar, meeting, disk
  def facts(info: '', url: self.url, date: '08/11', **links)
    described_class::Facts.new(
      row: { 'info' => info, 'url' => url }, fin_event_id: FINEventId.parse(url),
      row_date: SeasonBoard::RowDate.parse(date, '2026'), calendar: nil, meeting: nil, disk: nil, **links
    )
  end

  def meeting(results_acquired: false, mir_count: 0, cancelled: false)
    SeasonBoard::DbIndex::MeetingInfo.new(id: 5, description: 'M', code: 'm', header_date: nil, cancelled:,
                                          results_acquired:, manifest: true, mir_count:, mrr_count: 0)
  end

  ['ANNULLATA', 'gara annullata', 'Rinviata a data da destinarsi', 'RINVIO', 'Cancelled'].each do |info|
    it "detects cancellation from the info text #{info.inspect}" do
      expect(resolver.call(facts(info:)).state).to eq(:cancelled)
    end
  end

  it 'does not treat a blank or unrelated info text as cancelled' do
    expect(resolver.call(facts(info: 'Risultati')).state).to eq(:link_not_crawled)
  end

  it 'always includes the FIN id in the action params' do
    outcome = resolver.call(facts)
    expect(outcome.next_action).to eq(SeasonBoard::NextAction.new(kind: :crawl, params: { fin_event_id: '150091', url: }))
    expect(outcome.next_action[:url]).to eq(url)
  end

  it 'suggests :check_results only once the last date is past' do
    expect(resolver.call(facts(meeting: meeting, date: '11-12/11')).next_action).to be_nil
    outcome = resolver.call(facts(meeting: meeting, date: '10-11/11'))
    expect(outcome.state).to eq(:structure_committed)
    expect(outcome.detail).to eq(past: true)
    expect(outcome.next_action.params).to eq(fin_event_id: '150091', url:, meeting_id: 5)
  end

  it 'never suggests :check_results for a meeting with results' do
    expect(resolver.call(facts(meeting: meeting(mir_count: 1))).state).to eq(:committed_with_results)
    expect(resolver.call(facts(meeting: meeting(results_acquired: true))).next_action).to be_nil
  end

  it 'cancels on a cancelled meeting' do
    expect(resolver.call(facts(meeting: meeting(cancelled: true))).state).to eq(:cancelled)
  end

  it 'returns :not_linked (no action) without URL' do
    outcome = resolver.call(facts(url: ''))
    expect(outcome).to have_attributes(state: :not_linked, detail: {}, next_action: nil)
  end
end
