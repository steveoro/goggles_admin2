# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Row
  #
  # View-model for one FIN calendar row of the Season board (built by SeasonBoard::Builder).
  #
  # - state:        one of Builder::STATES (Symbol);
  # - state_detail: Hash with state-specific details (e.g. { phase: 3 } for :in_review);
  # - next_action:  NextAction (kind Symbol + params Hash) or nil; see Builder for the payloads;
  # - activity:     { crawl: ActivityLog::Entry|nil, extract: ActivityLog::Entry|nil };
  # - busy:         true while a (non-stale) crawl/extraction is queued or running for the FIN id
  #                 (an overlay, not a state: the UI should disable the action buttons);
  # - flags:        Array of Symbols (see Builder::FLAGS);
  # - calendar / disk_entry: the underlying DbIndex::CalendarInfo / DiskIndex::Entry (or nil).
  #
  Row = Data.define(
    :fin_event_id, :key, :date_text, :first_date, :last_date, :year, :name, :place, :url, :info,
    :calendar_id, :meeting_id, :meeting_description, :meeting_header_date, :mir_count, :mrr_count, :results_acquired,
    :state, :state_detail, :next_action, :activity, :busy, :flags, :calendar, :disk_entry
  ) do
    def busy? = busy
    def results_count = mir_count.to_i + mrr_count.to_i
    def linked? = meeting_id.present?
    def flag?(flag) = flags.include?(flag)
    def action?(kind) = next_action&.kind == kind
  end
end
