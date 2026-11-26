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
  # - activity:     { crawl:, extract:, prepare: } (ActivityLog::Entry|nil each, see ActivityLog::KINDS);
  # - busy:         true while a (non-stale) crawl/extraction/prepare is queued or running for the FIN id
  #                 (an overlay, not a state: the UI disables the POST action buttons);
  # - locked:       true while a job works on the row's files right now: a prepare job holds the source lease, or a
  #                 crawl/extraction/prepare of the FIN id is running (not stale). The review / commit links (GET) stay
  #                 enabled while the row is only busy (e.g. a prepare merely queued), and are disabled while locked
  #                 (optional, default false);
  # - flags:        Array of Symbols (see Builder::FLAGS);
  # - calendar / disk_entry: the underlying DbIndex::CalendarInfo / DiskIndex::Entry (or nil);
  # - pipeline: the PipelineIndex::Facts of the row's source (optional, default nil);
  # - adopted_link: the CalendarIndex::Link lent by the FIN 'Eventi' calendar to a row without its own URL (0.10.102:
  #   +url+ and +fin_event_id+ are then the adopted ones; flag :link_adopted; optional, default nil).
  #
  Row = Data.define(
    :fin_event_id, :key, :date_text, :first_date, :last_date, :year, :name, :place, :url, :info,
    :calendar_id, :meeting_id, :meeting_description, :meeting_header_date, :mir_count, :mrr_count, :results_acquired,
    :state, :state_detail, :next_action, :activity, :busy, :flags, :calendar, :disk_entry, :pipeline, :locked, :adopted_link
  ) do
    def initialize(pipeline: nil, locked: false, adopted_link: nil, **) = super

    def busy? = busy
    def locked? = locked
    def results_count = mir_count.to_i + mrr_count.to_i
    def linked? = meeting_id.present?
    def flag?(flag) = flags.include?(flag)
    def action?(kind) = next_action&.kind == kind
  end
end
