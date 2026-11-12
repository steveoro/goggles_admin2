# frozen_string_literal: true

# Helper building SeasonBoard::Row instances for the automation specs.
module SeasonBoardRows
  # options: action (NextAction kind), url, last_date, busy
  def board_row(fin_event_id:, state:, **options)
    action = options[:action]
    last_date = options.fetch(:last_date, Date.current - 3)
    busy = options.fetch(:busy, false)
    url = options.fetch(:url) { "https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/#{fin_event_id}:m.html" }
    SeasonBoard::Row.new(
      fin_event_id:, key: "k-#{fin_event_id}", date_text: '08/11', first_date: last_date, last_date:, year: '2026',
      name: "Meeting #{fin_event_id}", place: 'X', url:, info: nil, calendar_id: nil, meeting_id: nil, meeting_description: nil,
      meeting_header_date: nil, mir_count: 0, mrr_count: 0, results_acquired: false, state:, state_detail: {},
      next_action: action && SeasonBoard::NextAction.new(kind: action, params: { fin_event_id:, url: }),
      activity: { crawl: nil, extract: nil }, busy:, flags: [], calendar: nil, disk_entry: nil
    )
  end

  def board_result(rows)
    instance_double(SeasonBoard::Builder::Result, rows:)
  end
end
