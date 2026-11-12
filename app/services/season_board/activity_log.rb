# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::ActivityLog
  #
  # JSON-file log (default: 'crawler/data/season-board.json') of the latest crawl & manifest
  # extraction attempt for each FIN event id, so that the Season board can show what's
  # queued/running (and avoid starting a manual run on top of an automatic one).
  #
  # Persistence reuses FedernuotoWatch::StateStore (exclusive flock + atomic rename), so jobs
  # and web requests can update the file concurrently.
  #
  # File layout:
  #   { "entries" => { "<fin_event_id>" => { "crawl" => {...}, "extract" => {...} } } }
  # where each entry stores: origin, status, queued_at, started_at, finished_at (ISO8601), url, message.
  #
  # A 'running' entry older than RUNNING_STALE_AFTER (or a 'queued' one older than
  # QUEUED_STALE_AFTER) is considered stale: still reported, but no longer "busy".
  #
  class ActivityLog
    DEFAULT_PATH = Rails.root.join('crawler/data/season-board.json')

    KINDS = %i[crawl extract].freeze
    ORIGINS = %i[auto manual].freeze
    STATUSES = %i[queued running done failed].freeze
    FINAL_STATUSES = %i[done failed].freeze

    # Above MeetingCrawlJob's 30-minute hard timeout:
    RUNNING_STALE_AFTER = 40.minutes
    # The background worker runs one job at a time and a daily re-check can queue up to
    # SeasonRecheckJob::MAX_CRAWLS_PER_RUN crawls of up to ~36 minutes each (~9 hours in all):
    QUEUED_STALE_AFTER = 12.hours

    attr_reader :path

    # Configurable through config.x.season_board.activity_log_path (falls back to DEFAULT_PATH).
    def self.default_path
      Rails.configuration.x.season_board.activity_log_path.presence || DEFAULT_PATH
    end

    def initialize(path: self.class.default_path)
      @path = Pathname.new(path)
      @store = FedernuotoWatch::StateStore.new(path: @path)
    end

    # Records a new queued attempt (resetting any previous one for the same FIN id & kind).
    # Returns the new Entry.
    def queue!(fin_event_id, kind:, origin:, url: nil, message: nil)
      write_entry(fin_event_id, kind) do |_previous|
        {
          'origin' => check!(origin, ORIGINS, :origin).to_s, 'status' => 'queued',
          'queued_at' => now_iso, 'started_at' => nil, 'finished_at' => nil,
          'url' => url, 'message' => message
        }
      end
    end

    # Marks the attempt as running. Keeps queued_at/origin/url from a previous queued entry;
    # origin defaults to :manual when there's nothing to inherit. Returns the new Entry.
    def start!(fin_event_id, kind:, origin: nil, url: nil)
      write_entry(fin_event_id, kind) do |previous|
        inherit = previous && previous['status'] == 'queued' ? previous : {}
        origin = check!(origin || inherit['origin'] || :manual, ORIGINS, :origin)
        {
          'origin' => origin.to_s, 'status' => 'running',
          'queued_at' => inherit['queued_at'], 'started_at' => now_iso, 'finished_at' => nil,
          'url' => url || inherit['url'] || previous&.dig('url'), 'message' => nil
        }
      end
    end

    # Closes the attempt with status :done or :failed. Returns the new Entry.
    def finish!(fin_event_id, kind:, status:, message: nil)
      status = check!(status, FINAL_STATUSES, :status)
      write_entry(fin_event_id, kind) do |previous|
        (previous || { 'origin' => 'manual' }).merge('status' => status.to_s, 'finished_at' => now_iso, 'message' => message)
      end
    end

    # Returns { crawl: Entry|nil, extract: Entry|nil } for the FIN id.
    def for(fin_event_id)
      by_kind = entries_hash[normalize_id(fin_event_id)] || {}
      KINDS.index_with { |kind| build_entry(normalize_id(fin_event_id), kind, by_kind[kind.to_s]) }
    end

    # Returns the Entry for the FIN id & kind, or nil.
    def entry(fin_event_id, kind)
      self.for(fin_event_id)[check!(kind, KINDS, :kind)]
    end

    # True when the FIN id has a non-stale queued/running entry (of the given kind, or of any kind).
    def busy?(fin_event_id, kind: nil, now: Time.current)
      kinds = kind ? [check!(kind, KINDS, :kind)] : KINDS
      self.for(fin_event_id).values_at(*kinds).compact.any? { |e| e.busy?(now) }
    end

    # All non-stale queued/running entries (running first, then oldest first).
    def active(now: Time.current)
      all_entries.select { |e| e.busy?(now) }
                 .sort_by { |e| [e.running? ? 0 : 1, (e.started_at || e.queued_at).to_f] }
    end

    # Every stored Entry.
    def all_entries
      entries_hash.flat_map do |fin_id, by_kind|
        KINDS.filter_map { |kind| build_entry(fin_id, kind, by_kind[kind.to_s]) }
      end
    end

    # Most recent timestamp of the latest attempt of that kind, or nil.
    def last_attempt_at(fin_event_id, kind)
      entry(fin_event_id, kind)&.last_timestamp
    end

    private

    def entries_hash
      entries = @store.read['entries']
      entries.is_a?(Hash) ? entries : {}
    end

    def write_entry(fin_event_id, kind)
      fin_id = normalize_id(fin_event_id)
      kind = check!(kind, KINDS, :kind)
      raise ArgumentError, 'fin_event_id is required' if fin_id.blank?

      saved = nil
      @store.update do |state|
        state['entries'] = {} unless state['entries'].is_a?(Hash)
        by_kind = (state['entries'][fin_id] ||= {})
        saved = yield(by_kind[kind.to_s])
        by_kind[kind.to_s] = saved
        state
      end
      build_entry(fin_id, kind, saved)
    end

    def build_entry(fin_id, kind, hash)
      return nil unless hash.is_a?(Hash)

      Entry.new(
        fin_event_id: fin_id, kind: kind,
        origin: hash['origin'].to_s.presence&.to_sym, status: hash['status'].to_s.presence&.to_sym,
        queued_at: parse_time(hash['queued_at']), started_at: parse_time(hash['started_at']),
        finished_at: parse_time(hash['finished_at']), url: hash['url'], message: hash['message']
      )
    end

    def check!(value, allowed, name)
      sym = value.to_s.to_sym
      raise ArgumentError, "invalid #{name}: #{value.inspect} (allowed: #{allowed.join(', ')})" unless allowed.include?(sym)

      sym
    end

    def normalize_id(fin_event_id)
      fin_event_id.to_s.strip
    end

    def now_iso
      Time.current.iso8601
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    rescue ArgumentError
      nil
    end
  end
end
