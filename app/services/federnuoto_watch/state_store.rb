# frozen_string_literal: true

require 'fileutils'
require 'json'

module FedernuotoWatch
  #
  # = FedernuotoWatch::StateStore
  #
  # JSON-file persistence for the watcher state (default: 'crawler/data/federnuoto-watch.json';
  # see .default_path).
  #
  # State keys (all optional, String keys):
  # - 'url'            => watched URL;
  # - 'digest', 'rows' => latest snapshot;
  # - 'ack_digest', 'ack_rows' => last acknowledged snapshot (the baseline the pending change is computed from);
  # - 'change'         => pending (not yet acknowledged) change, or nil;
  # - 'removed_rows'   => (0.10.103) the rows FIN removed from the page since they were first seen, each with its
  #   'removed_at' (renamed or moved rows excluded, rows listed again dropped; see .track_removed): the Season board
  #   shows them, flagged "removed from FIN", while something local exists for their FIN id;
  # - 'last_checked', 'last_error', 'acknowledged_at' => timestamps & last error message.
  #
  # Every update is done under an exclusive file lock & written atomically, so that the job
  # and the web process (acknowledge action) can't overwrite each other's changes.
  #
  class StateStore
    DEFAULT_PATH = Rails.root.join('crawler/data/federnuoto-watch.json')
    # At most this many 'removed_rows' are kept (newest first).
    MAX_REMOVED_ROWS = 200

    attr_reader :path

    # Configured state file path (override with config.x.federnuoto_watch.state_path, as in the test env).
    def self.default_path
      Rails.configuration.x.federnuoto_watch.state_path.presence || DEFAULT_PATH
    end

    def initialize(path: self.class.default_path)
      @path = Pathname.new(path)
    end

    # Returns the current state Hash (empty when missing or unreadable).
    def read
      return {} unless path.exist?

      JSON.parse(path.read)
    rescue JSON::ParserError => e
      Rails.logger.error("[FedernuotoWatch::StateStore] invalid state file #{path}: #{e.message}")
      {}
    end

    # Yields the current state (a mutable Hash) under an exclusive lock and saves
    # whatever the block returns. Returns the saved state.
    def update
      locked do
        new_state = yield(read)
        write(new_state)
        new_state
      end
    end

    # Returns the pending change Hash, or nil.
    def pending_change
      read['change'].presence
    end

    # Marks the pending change as seen: the latest snapshot becomes the new baseline.
    # - expected_digest (0.10.103): when given, nothing is written unless the latest snapshot still has that digest (a
    #   newer snapshot landed since the caller looked, e.g. the hourly check racing a dismiss: its change must not be
    #   acknowledged unseen).
    # Nothing is written either without a pending change (a second caller of the same digest, e.g. the hourly watcher
    # and the planner pass at the same minute, or a dismiss right after an automatic acknowledge), or when the optional
    # block, yielded the state under the lock before any write, answers falsy (FedernuotoWatch::Acknowledge writes its
    # trace there first: a trace that cannot be written leaves the change pending).
    # Returns the saved state, or nil when refused.
    def acknowledge!(expected_digest: nil)
      locked do
        state = read
        next nil if state['change'].blank?
        next nil if expected_digest.present? && state['digest'] != expected_digest
        next nil if block_given? && !yield(state)

        state['ack_digest'] = state['digest']
        state['ack_rows'] = state['rows']
        state['change'] = nil
        state['acknowledged_at'] = Time.current.iso8601
        write(state)
        state
      end
    end

    # The 'removed_rows' after the snapshot went from +old_rows+ to +new_rows+ (0.10.103): the stored +removed+ list
    # plus the rows of +old_rows+ no longer listed that are true removals (not .renamed?), minus the rows listed again
    # (same key, or .renamed? onto a row of +new_rows+). A newly removed row gets its 'removed_at'; a known one keeps it.
    # Newest first, at most MAX_REMOVED_ROWS.
    def self.track_removed(removed, old_rows, new_rows, now: Time.current)
      listed = Array(new_rows).grep(Hash)
      listed_again = listed_again_check(listed)
      kept = Array(removed).grep(Hash).reject(&listed_again)
      kept_keys = kept.to_set { |row| row['key'] }
      fresh = Array(old_rows).grep(Hash).reject { |row| listed_again.call(row) || kept_keys.include?(row['key']) }
      stamp = now.iso8601
      (fresh.map { |row| row.merge('removed_at' => stamp) } + kept).first(MAX_REMOVED_ROWS)
    end

    # Lambda(row): true when the row is among +listed+, under its key or renamed.
    def self.listed_again_check(listed)
      keys = listed.to_set { |row| row['key'] }
      ->(row) { keys.include?(row['key']) || renamed?(row, listed) }
    end
    private_class_method :listed_again_check

    # True when +row+ (a row no longer listed under its key) is still among +rows+ under another key: same FIN id, or
    # same dates and place (SeasonBoard::CalendarIndex.watcher_key: a renamed meeting, a place spelled differently).
    def self.renamed?(row, rows)
      others = rows.reject { |other| other['key'] == row['key'] }
      fin_id = FINEventId.parse(row['url'])
      return true if fin_id && others.any? { |other| FINEventId.parse(other['url']) == fin_id }

      key = SeasonBoard::CalendarIndex.watcher_key(row)
      key.present? && others.any? { |other| SeasonBoard::CalendarIndex.watcher_key(other) == key }
    rescue StandardError
      false
    end

    private

    # Yields under the exclusive file lock; returns the block value.
    def locked(&)
      FileUtils.mkdir_p(path.dirname)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write(state)
      tmp_path = "#{path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(state))
      File.rename(tmp_path, path)
    end
  end
end
