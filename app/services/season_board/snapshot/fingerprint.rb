# frozen_string_literal: true

require 'digest'

module SeasonBoard
  class Snapshot
    #
    # = SeasonBoard::Snapshot::Fingerprint
    #
    # Cheap digest of what a Season board build depends on (a few stat calls and 3 small queries,
    # no file content read), used to tell whether a stored board summary is still current:
    #
    # - the summary format (Snapshot::FORMAT_VERSION), the season id and the current date
    #   (the state rules compare the row dates with today);
    # - the mtimes of the watcher state file (FIN calendar rows) and of the board activity log;
    # - the mtimes of the 5 season folders scanned by DiskIndex (DiskIndex::SEASON_FOLDERS): they
    #   change when a file is added, removed or renamed (atomic rewrites included), not on an
    #   in-place edit (hence the max age of the stored summaries);
    # - count & max(updated_at) of the season calendars and meetings;
    # - the id of the last Ops::Event of the EVENT_KINDS (Phase 6 commit, staging purge, calendar link).
    #
    class Fingerprint
      # Ops::Event kinds that change the board (as written by the 01 instrumentation).
      EVENT_KINDS = %w[datafix.committed datafix.purged board.calendar_linked].freeze

      # Returns the digest (String) for the season id; see #initialize for the options.
      def self.digest(season_id, **options)
        new(season_id:, **options).digest
      end

      # == Params
      # - season_id: board season id (Integer or String);
      # - data_dir: base 'crawler/data' folder (default: DiskIndex.default_data_dir);
      # - watch_path / activity_path: watcher state file / board activity log (defaults: their configured paths);
      # - today: reference date.
      def initialize(season_id:, data_dir: nil, watch_path: nil, activity_path: nil, today: Date.current)
        @season_id = season_id.to_i
        @data_dir = Pathname.new(data_dir || DiskIndex.default_data_dir)
        @watch_path = watch_path || FedernuotoWatch::StateStore.default_path
        @activity_path = activity_path || ActivityLog.default_path
        @today = today
      end

      # SHA256 hex digest of #components.
      def digest
        Digest::SHA256.hexdigest(JSON.generate(components))
      end

      # Hash of the fingerprint components (JSON-able).
      def components
        {
          'format' => Snapshot::FORMAT_VERSION, 'season_id' => @season_id, 'today' => @today.iso8601,
          'files' => { 'watch' => mtime(@watch_path), 'activity' => mtime(@activity_path) },
          'folders' => DiskIndex::SEASON_FOLDERS.index_with { |folder| mtime(@data_dir.join(folder, @season_id.to_s)) },
          'calendars' => db_facts(GogglesDb::Calendar), 'meetings' => db_facts(GogglesDb::Meeting),
          'last_event_id' => last_event_id
        }
      end

      private

      # "<seconds>.<nanoseconds>" of the path mtime, or nil when missing.
      def mtime(path)
        time = File.stat(path.to_s).mtime
        "#{time.to_i}.#{time.nsec}"
      rescue SystemCallError
        nil
      end

      # [row count, max updated_at] of the season rows of the model (unscoped: no default eager loading).
      def db_facts(model)
        count, max_updated_at = model.unscoped.where(season_id: @season_id)
                                     .pick(Arel.sql('COUNT(*)'), Arel.sql("MAX(#{model.table_name}.updated_at)"))
        [count.to_i, max_updated_at.respond_to?(:iso8601) ? max_updated_at.iso8601(6) : max_updated_at&.to_s]
      end

      def last_event_id
        Ops.safely { Ops::Event.where(kind: EVENT_KINDS).maximum(:id) if Ops.available? }
      end
    end
  end
end
