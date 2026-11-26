# frozen_string_literal: true

module SeasonBoard
  class Snapshot
    #
    # = SeasonBoard::Snapshot::Summary
    #
    # Read-only board summary returned by SeasonBoard::Snapshot.fetch / .read / .store! (see the
    # Snapshot class comment for the meaning of each member). Built from the plain stored payload,
    # which stays available as #payload.
    #
    Summary = Data.define(
      :season_id, :rows, :state_counts, :unlinked_count, :done_count, :unmatched_sources, :board_sql_paths,
      :warnings, :snapshot_checked_at, :built_at, :taken_at, :fingerprint, :stored, :payload, :off_board_sources
    ) do
      def initialize(off_board_sources: [], **) = super

      # Builds the Summary from a payload Hash (String keys, see Snapshot::Payload).
      # - stored: true when the payload is the one stored in the ops DB;
      # - taken_at: time the payload was stored (or built, when not stored).
      def self.from_payload(payload, stored:, taken_at:)
        new(
          season_id: payload['season_id'], rows: Array(payload['rows']).map { |row| Row.from_payload(row) },
          **counts_from(payload),
          unmatched_sources: Array(payload['unmatched_sources']).map { |hash| UnmatchedSource.from_payload(hash) },
          off_board_sources: Array(payload['off_board_sources']).map { |hash| UnmatchedSource.from_payload(hash) },
          board_sql_paths: Array(payload['board_sql_paths']), warnings: Array(payload['warnings']),
          snapshot_checked_at: parse_time(payload['snapshot_checked_at']), built_at: parse_time(payload['built_at']),
          taken_at:, fingerprint: payload['fingerprint'], stored:, payload:
        )
      end

      # { state_counts:, unlinked_count:, done_count: } from the payload.
      def self.counts_from(payload)
        {
          state_counts: (payload['state_counts'] || {}).to_h { |state, count| [state.to_sym, count.to_i] },
          unlinked_count: payload['unlinked_count'].to_i, done_count: payload['done_count'].to_i
        }
      end

      def self.parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      # True when the summary comes from (or was saved to) the ops DB; false when built live without it.
      def stored? = stored

      # Row for the FIN event id (String or Integer), or nil.
      def row_for(fin_event_id)
        id = fin_event_id.to_s.strip
        return nil if id.empty?

        rows.find { |row| row.fin_event_id == id }
      end

      # Rows in the given state (Symbol or String).
      def rows_in(state)
        rows.select { |row| row.state == state.to_sym }
      end

      # Rows with a queued or running crawl/extraction.
      def busy_rows
        rows.select(&:busy?)
      end
    end
  end
end
