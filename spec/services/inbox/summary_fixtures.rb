# frozen_string_literal: true

# Helpers building SeasonBoard::Snapshot::Summary objects (the board summary read by the inbox sources) from plain
# payload rows, plus an Inbox::Context around them.
module InboxSummaryFixtures
  # +options+: name, busy, last_date (row attributes); any other key goes into the next action params.
  def board_row_payload(fin_event_id, state, kind = nil, **options)
    params = options.except(:name, :busy, :last_date)
    {
      'fin_event_id' => fin_event_id, 'name' => options.fetch(:name, "Meeting #{fin_event_id}"), 'state' => state.to_s,
      'url' => "https://fin.example/#{fin_event_id}", 'date_text' => '08/11', 'year' => '2026', 'place' => 'Roma',
      'last_date' => options.fetch(:last_date, '2026-11-08'), 'busy' => options.fetch(:busy, false),
      'next_action' => kind && { 'kind' => kind.to_s, 'params' => { 'fin_event_id' => fin_event_id }.merge(params.stringify_keys) }
    }
  end

  def board_summary(rows: [], unmatched: [], season_id: 262, built_at: Time.zone.parse('2026-11-23 09:00'))
    payload = { 'season_id' => season_id, 'built_at' => built_at.iso8601, 'state_counts' => {}, 'rows' => rows,
                'unmatched_sources' => unmatched, 'board_sql_paths' => [], 'warnings' => [] }
    SeasonBoard::Snapshot::Summary.from_payload(payload, stored: true, taken_at: built_at)
  end

  def inbox_context(board_snapshot: nil, now: Time.zone.parse('2026-11-23 10:00'), **options)
    Inbox::Context.new(season: nil, board_snapshot:, now:, ops_available: true, api_url: 'http://localhost:8081', **options)
  end
end
