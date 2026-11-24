# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Snapshot
  #
  # Stored summary of the Season board (ops DB, Ops::Snapshot key 'season_board:<season_id>'), so that
  # the pages summarising the board (the dashboard) and the board POST actions read it without a full
  # Builder#call (DiskIndex scanning 5 folders with JSON probes, DbIndex queries, ActivityLog...).
  #
  # == Freshness
  # Every stored summary carries a Snapshot::Fingerprint taken BEFORE its build (file & folder mtimes,
  # calendar & meeting counts, last commit/purge/link event, today). .fetch serves it only when the
  # current fingerprint is the same AND it was stored less than MAX_AGE ago (an in-place edit of a
  # phase file changes no folder mtime); otherwise it rebuilds the board and stores the new summary.
  # The ops DB missing never breaks a caller: .fetch then builds live (no store), .store! returns an
  # unsaved summary, .invalidate! does nothing.
  #
  # == API
  # - .fetch(season, max_age: MAX_AGE, builder: nil) => Summary (stored & fresh, else rebuilt); nil for a nil season
  # - .build!(season, builder: nil)                    => Builder::Result: full build, storing its summary
  #                                                       (board page, CrawlPlanner, SeasonRecheckJob)
  # - .store!(season, result, fingerprint: nil)        => Summary of a Builder::Result, stored when possible
  #                                                       (pass the fingerprint taken before the build)
  # - .read(season)                                    => stored Summary or nil (no freshness check, no build)
  # - .invalidate!(season)                             => deletes the stored summary (next to every
  #                                                       SeasonBoard::Notifier.ping); true when one was deleted
  # - .key_for(season)                                 => 'season_board:<season_id>'
  # (+season+: a GogglesDb::Season or its id; +builder+: object responding to #call with a Builder::Result.)
  #
  # == Summary (Snapshot::Summary)
  # - season_id: Integer;
  # - rows: Array of Snapshot::Row, in FIN calendar order: fin_event_id, key, name, date_text, year,
  #   first_date, last_date (Date), place, url, info, state (Symbol), state_detail (Hash, Symbol keys),
  #   next_action (SeasonBoard::NextAction: kind Symbol + params Hash, see StateResolver; nil when none),
  #   busy (Boolean, a crawl/extraction/prepare queued or running), flags (Array of Symbols, RowFlags::FLAGS),
  #   meeting_id, calendar_id; plus #busy?, #flag?(flag), #action?(kind), #linked?.
  #   SeasonBoard::ActionPaths.target_for(row.next_action) gives the action path & HTTP method;
  # - state_counts: Hash of state Symbol => row count (row order); unlinked_count: rows without FIN link;
  #   done_count: past rows committed with results (both hidden by default on the board);
  # - unmatched_sources: Array of Snapshot::UnmatchedSource (pending files without FIN id: base, bases,
  #   pending kind :in_review/:source/:sql/:manifest, review_path, phase, paths);
  # - board_sql_paths: board SQL scripts (backfill/calendar link) awaiting push (absolute path Strings);
  # - warnings: Array of Strings;
  # - snapshot_checked_at: Time of the last FIN calendar check by the watcher (nil when never);
  # - built_at: Time of the board build; taken_at: Time the summary was stored (or built, when not stored);
  # - fingerprint: digest the summary was built with; stored: false when built live without the ops DB;
  # - payload: the plain stored Hash (String keys; only Hash/Array/String/Integer/Boolean/nil values,
  #   dates & times as ISO 8601 Strings: see Snapshot::Payload).
  # Helpers: #stored?, #row_for(fin_event_id), #rows_in(state), #busy_rows.
  #
  class Snapshot
    # Bump when the payload layout changes (part of the fingerprint: older payloads are never served).
    # 2: phase 10 pipeline states (:prepare_failed, :needs_review, :ready_to_commit) and actions (:prepare, :commit).
    FORMAT_VERSION = 2

    KEY_PREFIX = 'season_board:'

    # A stored summary older than this is rebuilt even when its fingerprint matches.
    MAX_AGE = 10.minutes

    SOURCE = 'SeasonBoard::Snapshot'

    class << self
      # Ops::Snapshot key for the season (GogglesDb::Season or id).
      def key_for(season)
        "#{KEY_PREFIX}#{season_id_of(season)}"
      end

      # Returns the fresh stored Summary of the season, or rebuilds the board (Builder#call), stores
      # and returns the new Summary. Builds live (without storing) when the ops DB is not available.
      def fetch(season, max_age: MAX_AGE, builder: nil)
        return nil if season.nil?

        fingerprint = current_fingerprint(season)
        if fingerprint
          record = Ops.safely { Ops::Snapshot.read(key_for(season)) }
          summary = fresh_summary(record, fingerprint, max_age)
          return summary if summary
        end

        store!(season, (builder || Builder.new(season:)).call, fingerprint: fingerprint || false)
      end

      # Runs a full board build and stores its Summary (when the ops DB is available).
      # Returns the Builder::Result. A failing store is only logged.
      def build!(season, builder: nil)
        fingerprint = current_fingerprint(season)
        result = (builder || Builder.new(season:)).call
        Ops.safely { store!(season, result, fingerprint:) } if fingerprint
        result
      end

      # Stores the Summary of the Builder::Result (when the ops DB is available) and returns it.
      # - fingerprint: digest taken before the build; nil computes it now; false never stores.
      def store!(season, result, fingerprint: nil)
        fingerprint = current_fingerprint(season) if fingerprint.nil?
        payload = Payload.call(result, season_id: season_id_of(season), fingerprint: fingerprint || nil)
        record = fingerprint ? Ops.safely { Ops::Snapshot.write!(key_for(season), payload, source: SOURCE) } : nil
        Summary.from_payload(payload, stored: record.present?, taken_at: record&.taken_at || Time.current)
      end

      # Stored Summary of the season (whatever its age or fingerprint), or nil.
      def read(season)
        return nil if season_id_of(season).nil?

        record = Ops.safely { Ops::Snapshot.read(key_for(season)) if Ops.available? }
        summary_from(record)
      end

      # Deletes the stored Summary of the season. Never raises; true when a row was deleted.
      def invalidate!(season)
        Ops.safely(false) do
          next false if season_id_of(season).nil? || !Ops.available?

          Ops::Snapshot.where(key: key_for(season)).delete_all.positive?
        end
      end

      # Current fingerprint digest of the season, or nil when the ops DB is not available
      # (nothing to compare with) or the fingerprint can't be computed.
      def current_fingerprint(season)
        return nil unless Ops.available?

        Fingerprint.digest(season_id_of(season))
      rescue StandardError => e
        Rails.logger.warn("[SeasonBoard::Snapshot] fingerprint failed: #{e.class}: #{e.message}")
        nil
      end

      private

      def season_id_of(season)
        return season.id if season.respond_to?(:id)

        Integer(season.to_s, exception: false)
      end

      def fresh_summary(record, fingerprint, max_age)
        return nil unless record && record.taken_at > max_age.ago
        return nil unless record.payload.is_a?(Hash) && record.payload['fingerprint'] == fingerprint

        summary_from(record)
      end

      def summary_from(record)
        return nil unless record&.payload.is_a?(Hash)

        Summary.from_payload(record.payload, stored: true, taken_at: record.taken_at)
      rescue StandardError => e
        Rails.logger.warn("[SeasonBoard::Snapshot] unreadable stored summary: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
