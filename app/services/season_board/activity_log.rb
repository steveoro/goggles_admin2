# frozen_string_literal: true

require 'digest'

module SeasonBoard
  #
  # = SeasonBoard::ActivityLog
  #
  # JSON-file log (default: 'crawler/data/season-board.json') of the latest crawl, manifest
  # extraction and Data-Fix prepare attempt for each FIN event id, so that the Season board can show
  # what's queued/running (and avoid starting a manual run on top of an automatic one).
  #
  # Persistence reuses FedernuotoWatch::StateStore (exclusive flock + atomic rename), so jobs
  # and web requests can update the file concurrently.
  #
  # File layout:
  #   { "entries" => { "<fin_event_id>" => { "crawl" => {...}, "extract" => {...}, "prepare" => {...} } } }
  # (unknown kinds found in the file are ignored: only KINDS are read.)
  # where each entry stores: origin, status, queued_at, started_at, finished_at (ISO8601), url, message, and the
  # optional (phase 15) label (shown instead of the FIN id) and heartbeat_at (written by a long job at each poll),
  # plus (0.10.99) run_id (the Ops::PipelineRun of a prepare, kept from queue! to finish!) and reason (why the entry
  # was closed by SeasonBoard::ActivityReconciler, e.g. LOST_REASON).
  #
  # Phase 15: the manual crawls & extractions of the Sources pages use a source key instead of a FIN id
  # ('src:<sha1>', see .source_key), so the same strip, "In progress" zone and busy checks show them.
  #
  # A 'running' entry older than RUNNING_STALE_AFTER (or a 'queued' one older than
  # QUEUED_STALE_AFTER) is considered stale: still reported, but no longer "busy". A running entry
  # whose heartbeat is younger than HEARTBEAT_STALE_AFTER is never stale (a long calendar crawl).
  #
  # Each instance reads the file once and keeps the entries in memory (a Season board build asks
  # #for once per row): the writes made through the same instance reset that cache, while
  # #reload! re-reads the file to see the writes made by other instances (other processes, jobs).
  #
  class ActivityLog # rubocop:disable Metrics/ClassLength
    DEFAULT_PATH = Rails.root.join('crawler/data/season-board.json')

    # (:prepare = DataFixPrepareJob, phase 10; commits are tracked by Ops::CommitReport, not here)
    KINDS = %i[crawl extract prepare].freeze
    ORIGINS = %i[auto manual].freeze
    STATUSES = %i[queued running done failed].freeze
    FINAL_STATUSES = %i[done failed].freeze

    # Above MeetingCrawlJob's 30-minute hard timeout:
    RUNNING_STALE_AFTER = 40.minutes
    # The background worker runs one job at a time and a daily re-check can queue up to
    # SeasonRecheckJob::MAX_CRAWLS_PER_RUN crawls of up to ~36 minutes each (~9 hours in all):
    QUEUED_STALE_AFTER = 12.hours
    # A running entry with a heartbeat younger than this is busy, whatever its start time (the jobs beat every 10 s).
    HEARTBEAT_STALE_AFTER = 5.minutes
    # Prefix of the keys of the Sources work (no FIN id).
    SOURCE_KEY_PREFIX = 'src:'
    # Reason of an entry closed because its job was no longer in the queue (SeasonBoard::ActivityReconciler).
    LOST_REASON = 'lost'

    attr_reader :path

    # Key of a Sources crawl or extraction: 'src:<sha1 of kind and target>' (target: the URL or the file path).
    def self.source_key(kind, target)
      "#{SOURCE_KEY_PREFIX}#{Digest::SHA1.hexdigest("#{kind}|#{target}")}"
    end

    # True for a key made by .source_key.
    def self.source_key?(key)
      key.to_s.start_with?(SOURCE_KEY_PREFIX)
    end

    # Configurable through config.x.season_board.activity_log_path (falls back to DEFAULT_PATH).
    def self.default_path
      Rails.configuration.x.season_board.activity_log_path.presence || DEFAULT_PATH
    end

    def initialize(path: self.class.default_path)
      @path = Pathname.new(path)
      @store = FedernuotoWatch::StateStore.new(path: @path)
    end

    # Records a new queued attempt (resetting any previous one for the same FIN id & kind).
    # - run_id: the Ops::PipelineRun of the attempt (a prepare), kept until finish! (read by ActivityReconciler).
    # Returns the new Entry.
    def queue!(fin_event_id, kind:, origin:, url: nil, message: nil, label: nil, run_id: nil) # rubocop:disable Metrics/ParameterLists
      write_entry(fin_event_id, kind) do |_previous|
        entry = {
          'origin' => check!(origin, ORIGINS, :origin).to_s, 'status' => 'queued',
          'queued_at' => now_iso, 'started_at' => nil, 'finished_at' => nil,
          'url' => url, 'message' => message
        }
        with_run_id(with_label(entry, label), run_id)
      end
    end

    # Marks the attempt as running. Keeps queued_at/origin/url/run_id from a previous queued entry;
    # origin defaults to :manual when there's nothing to inherit. Returns the new Entry.
    def start!(fin_event_id, kind:, origin: nil, url: nil, label: nil) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      write_entry(fin_event_id, kind) do |previous|
        inherit = previous && previous['status'] == 'queued' ? previous : {}
        origin = check!(origin || inherit['origin'] || :manual, ORIGINS, :origin)
        entry = {
          'origin' => origin.to_s, 'status' => 'running',
          'queued_at' => inherit['queued_at'], 'started_at' => now_iso, 'finished_at' => nil,
          'url' => url || inherit['url'] || previous&.dig('url'), 'message' => nil
        }
        with_run_id(with_label(entry, label || previous&.dig('label')), inherit['run_id'])
      end
    end

    # Writes the heartbeat of a running attempt (a long job calls it at each poll, see HEARTBEAT_STALE_AFTER).
    # Returns the Entry, or nil when the attempt is not running.
    def heartbeat!(fin_event_id, kind:)
      return unless entry(fin_event_id, kind)&.running?

      write_entry(fin_event_id, kind) do |previous|
        previous['status'] == 'running' ? previous.merge('heartbeat_at' => now_iso) : previous
      end
    end

    # Closes the attempt with status :done or :failed (+reason+: optional code, e.g. LOST_REASON). Returns the new Entry.
    def finish!(fin_event_id, kind:, status:, message: nil, reason: nil)
      status = check!(status, FINAL_STATUSES, :status)
      write_entry(fin_event_id, kind) do |previous|
        closed_hash(previous, status, message, reason)
      end
    end

    # Closes +entry+ (an Entry read before) like #finish!, but only when the stored attempt is still the same one (same
    # status, queued_at and started_at): a job that started, or a new attempt queued, in the meantime is left alone.
    # Returns the new Entry, or nil when the stored attempt changed.
    def finish_unchanged!(entry, status:, message: nil, reason: nil)
      status = check!(status, FINAL_STATUSES, :status)
      applied = false
      saved = write_entry(entry.fin_event_id, entry.kind) do |previous|
        next previous unless same_attempt?(build_entry(entry.fin_event_id, entry.kind, previous), entry)

        applied = true
        closed_hash(previous, status, message, reason)
      end
      applied ? saved : nil
    end

    # Records a finished attempt (status :done or :failed) of +kind+ for every key of +keys+ in ONE locked write (e.g. a
    # Sources crawl that brought the files of several FIN meetings), skipping the keys whose entry of that kind is busy
    # (queued or running, not stale): their own job will close them. Returns the keys written.
    def record_many!(keys, kind:, status:, origin:, message: nil, url: nil, started_at: nil) # rubocop:disable Metrics/ParameterLists
      kind = check!(kind, KINDS, :kind)
      attempt = {
        'origin' => check!(origin, ORIGINS, :origin).to_s, 'status' => check!(status, FINAL_STATUSES, :status).to_s,
        'queued_at' => nil, 'started_at' => started_at&.iso8601, 'finished_at' => now_iso, 'url' => url, 'message' => message
      }
      ids = Array(keys).map { |key| normalize_id(key) }.compact_blank.uniq
      ids.empty? ? [] : write_many(ids, kind, attempt)
    end

    # Returns { crawl: Entry|nil, extract: Entry|nil, prepare: Entry|nil } (one key per KINDS) for the FIN id.
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

    # Drops the entries read so far: the next read loads the file again. Returns self.
    def reload!
      @entries_hash = nil
      self
    end

    private

    # Stored entries (read once per instance, see #reload!).
    def entries_hash
      @entries_hash ||= begin
        entries = @store.read['entries']
        entries.is_a?(Hash) ? entries : {}
      end
    end

    def write_entry(fin_event_id, kind)
      fin_id = normalize_id(fin_event_id)
      kind = check!(kind, KINDS, :kind)
      raise ArgumentError, 'fin_event_id is required' if fin_id.blank?

      saved = nil
      begin
        @store.update do |state|
          state['entries'] = {} unless state['entries'].is_a?(Hash)
          by_kind = (state['entries'][fin_id] ||= {})
          saved = yield(by_kind[kind.to_s])
          saved.nil? ? by_kind.delete(kind.to_s) : by_kind[kind.to_s] = saved
          state['entries'].delete(fin_id) if by_kind.empty?
          state
        end
      ensure
        reload!
      end
      build_entry(fin_id, kind, saved)
    end

    # Writes +attempt+ (a stored entry Hash) under each of +ids+ whose +kind+ entry is not busy, in one locked update.
    # Returns the ids written.
    def write_many(ids, kind, attempt)
      written = []
      @store.update do |state|
        state['entries'] = {} unless state['entries'].is_a?(Hash)
        ids.each do |fin_id|
          by_kind = (state['entries'][fin_id] ||= {})
          next if build_entry(fin_id, kind, by_kind[kind.to_s])&.busy?

          by_kind[kind.to_s] = attempt.dup
          written << fin_id
        end
        state
      end
      written
    ensure
      reload!
    end

    # Time members of an Entry (ISO 8601 Strings in the file).
    TIME_KEYS = %w[queued_at started_at finished_at heartbeat_at].freeze
    private_constant :TIME_KEYS

    def build_entry(fin_id, kind, hash)
      return nil unless hash.is_a?(Hash)

      Entry.new(
        fin_event_id: fin_id, kind: kind,
        origin: hash['origin'].to_s.presence&.to_sym, status: hash['status'].to_s.presence&.to_sym,
        url: hash['url'], message: hash['message'], label: hash['label'].presence, run_id: hash['run_id'].presence,
        reason: hash['reason'].presence, **TIME_KEYS.to_h { |key| [key.to_sym, parse_time(hash[key])] }
      )
    end

    # The stored Hash of a closed attempt (+previous+: the stored one, or nil). A +reason+ replaces any former one.
    def closed_hash(previous, status, message, reason)
      hash = (previous || { 'origin' => 'manual' }).merge('status' => status.to_s, 'finished_at' => now_iso, 'message' => message)
      reason.present? ? hash.merge('reason' => reason.to_s) : hash.except('reason')
    end

    # True when +stored+ (an Entry or nil) is the attempt +expected+ was read from.
    def same_attempt?(stored, expected)
      stored.present? && stored.status == expected.status && stored.queued_at == expected.queued_at &&
        stored.started_at == expected.started_at
    end

    # The entry with its 'run_id' key when there is one (the other entries keep their former layout).
    def with_run_id(entry, run_id)
      run_id.present? ? entry.merge('run_id' => run_id) : entry
    end

    # The entry with its 'label' key when there is one (FIN entries keep their former layout).
    def with_label(entry, label)
      label.present? ? entry.merge('label' => label) : entry
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
