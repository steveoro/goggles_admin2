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
  # - 'last_checked', 'last_error', 'acknowledged_at' => timestamps & last error message.
  #
  # Every update is done under an exclusive file lock & written atomically, so that the job
  # and the web process (acknowledge action) can't overwrite each other's changes.
  #
  class StateStore
    DEFAULT_PATH = Rails.root.join('crawler/data/federnuoto-watch.json')

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
      FileUtils.mkdir_p(path.dirname)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
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
    # Returns the saved state.
    def acknowledge!
      update do |state|
        state['ack_digest'] = state['digest']
        state['ack_rows'] = state['rows']
        state['change'] = nil
        state['acknowledged_at'] = Time.current.iso8601
        state
      end
    end

    private

    def write(state)
      tmp_path = "#{path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(state))
      File.rename(tmp_path, path)
    end
  end
end
