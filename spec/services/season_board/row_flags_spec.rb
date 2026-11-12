# frozen_string_literal: true

require 'rails_helper'

# (Disk-related flags are also covered, with real fixtures, in builder_spec.rb)
RSpec.describe SeasonBoard::RowFlags do
  subject(:row_flags) { described_class.new(season:, db_index:) }

  let(:season) { FactoryBot.build_stubbed(:season, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
  let(:db_index) { instance_double(SeasonBoard::DbIndex, duplicate_fin_event_ids: ['150091']) }
  let(:no_activity) { { crawl: nil, extract: nil } }

  # links: calendar, meeting, disk
  def facts(date: '08/11', fin_event_id: '150092', **links)
    SeasonBoard::StateResolver::Facts.new(
      row: {}, fin_event_id:, row_date: SeasonBoard::RowDate.parse(date, '2026'), calendar: nil, meeting: nil, disk: nil, **links
    )
  end

  def entry(status, kind: :crawl)
    SeasonBoard::ActivityLog::Entry.new(fin_event_id: '150092', kind:, origin: :auto, status:, queued_at: Time.current,
                                        started_at: nil, finished_at: nil, url: nil, message: nil)
  end

  it 'returns no flags for a plain row' do
    expect(row_flags.call(facts, :link_not_crawled, no_activity, false)).to eq([])
  end

  it 'flags busy & failed attempts' do
    activity = { crawl: entry(:failed), extract: entry(:failed, kind: :extract) }
    expect(row_flags.call(facts, :link_not_crawled, activity, true)).to eq(%i[busy crawl_failed extract_failed])
  end

  it 'flags dates outside the season & unparsable dates' do
    expect(row_flags.call(facts(date: '20/09'), :not_linked, no_activity, false)).to eq([:outside_season])
    expect(row_flags.call(facts(date: '??'), :not_linked, no_activity, false)).to eq([:unparsable_date])
  end

  it 'flags duplicated calendars & calendars pointing to a missing meeting' do
    calendar = instance_double(SeasonBoard::DbIndex::CalendarInfo, meeting_id: 42)
    expect(row_flags.call(facts(fin_event_id: '150091', calendar:), :link_not_crawled, no_activity, false))
      .to eq(%i[missing_meeting duplicate_calendar])
    expect(row_flags.duplicate_fin_event_ids).to eq(Set['150091'])
  end
end
