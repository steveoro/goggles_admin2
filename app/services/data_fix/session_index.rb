# frozen_string_literal: true

module DataFix
  # SessionIndex: read-only listing of the Data-Fix "sessions", one per source.
  # A source is listed when it has phase files in <data_dir>/results.new/<numeric season>/
  # ('<stem>-phase<1..5>.json') and/or staging rows (+data_import_*+, by +phase_file_path+).
  #
  # Nothing is cached: build a new instance to rescan.
  class SessionIndex
    PHASE_GLOB = '*-phase[1-5].json'

    # One source/session.
    # - source_path: path as stored in the staging rows when present, else the canonical
    #   '<dir>/<stem>.json' relative to Rails.root (this is the +file_path+ for the review pages);
    # - season_id: Integer or nil; highest_phase: Integer (0 when no phase file);
    # - mtime: Time of the newest phase file, or nil; staging_rows: Integer (individual results count);
    # - source_exists: true when the source file is still on disk.
    Row = Data.define(:source_path, :season_id, :highest_phase, :mtime, :staging_rows, :source_exists) do
      def source_exists? = source_exists
      def staging? = staging_rows.positive?
      def name = File.basename(source_path.to_s)

      # Whole days since the last phase file change (nil when unknown).
      def idle_days(now = Time.current)
        mtime && ((now - mtime) / 1.day).floor
      end

      # True for staging rows whose source file is gone (only "Purge" makes sense).
      def orphan? = staging? && !source_exists?
    end

    attr_reader :data_dir

    def initialize(data_dir: SeasonBoard::DiskIndex.default_data_dir)
      @data_dir = Pathname.new(data_dir)
    end

    # All the rows, most recently touched first (staging-only sources last).
    # @return [Array<Row>]
    def rows
      @rows ||= build.sort_by { |row| [row.mtime ? 0 : 1, -(row.mtime&.to_f || 0), row.source_path] }
    end

    # Row for the given source path (any spelling that resolves to the same file), or nil.
    def for(source_path)
      key = normalize(source_path)
      rows.find { |row| normalize(row.source_path) == key }
    end

    # Rows idle for +days+ days or more.
    def idle(days: 3, now: Time.current)
      rows.select { |row| row.idle_days(now)&.>=(days) }
    end

    private

    def build
      disk = scan_disk
      staging = staging_counts
      keys = (disk.keys | staging.keys.map { |path| normalize(path) }.uniq)
      staging_by_key = staging.group_by { |path, _count| normalize(path) }
      keys.map { |key| build_row(key, disk[key], staging_by_key[key]) }
    end

    # Hash of normalized source path => { phases: { n => path } }
    def scan_disk
      Dir.glob(data_dir.join('results.new', '[0-9]*', PHASE_GLOB).to_s).each_with_object({}) do |path, memo|
        match = SeasonBoard::DiskIndex::PHASE_REGEXP.match(File.basename(path))
        next unless match

        source = File.join(File.dirname(path), "#{match[:stem]}.json")
        (memo[normalize(source)] ||= { source:, phases: {} })[:phases][match[:phase].to_i] = path
      end
    end

    # One grouped count: Hash of phase_file_path => rows count.
    def staging_counts
      GogglesDb::DataImportMeetingIndividualResult.where.not(phase_file_path: [nil, ''])
                                                  .group(:phase_file_path).count
    end

    def build_row(key, disk_entry, staging_entries)
      source = staging_entries&.first&.first || disk_entry[:source]
      phases = disk_entry ? disk_entry[:phases] : {}
      Row.new(
        source_path: staging_entries ? source : relative(source), season_id: season_of(source),
        highest_phase: phases.keys.max || 0,
        mtime: phases.values.filter_map { |path| mtime_of(path) }.max,
        staging_rows: staging_entries ? staging_entries.sum { |_path, count| count } : 0,
        source_exists: File.exist?(key)
      )
    end

    def normalize(path)
      Pathname.new(path.to_s).expand_path(Rails.root).to_s
    end

    def relative(path)
      pathname = Pathname.new(path.to_s)
      if pathname.absolute?
        pathname.relative_path_from(Rails.root).to_s.then { |rel| rel.start_with?('..') ? path.to_s : rel }
      else
        path.to_s
      end
    end

    def season_of(path)
      Integer(File.basename(File.dirname(path.to_s)), exception: false)
    end

    def mtime_of(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end
  end
end
