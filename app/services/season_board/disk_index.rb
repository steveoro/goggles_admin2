# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::DiskIndex
  #
  # Indexes the Data-Fix files of a season by FIN event id.
  #
  # File basenames can't be predicted from the FIN calendar row (auto-crawled files are named
  # from the meeting page header), so the FIN id is read from the file CONTENT
  # (top-level 'meetingURL' / 'manifestURL', see FINEventId & SourceProbe) and then shared by
  # all the siblings having the same "base" name:
  #
  # - <data_dir>/results.new/<season>/  (pending work)
  #   - '<base>.json'               => LT2 crawler output (or an LT4 file, detected by content)
  #   - '<base>-lt4.json'           => LT4 working copy, or manifest-derived source ('_meta.meeting_only')
  #   - '<base>-lt4-phaseN.json'    => Data-Fix phase files
  #   - 'NNNN-<base>-lt4.sql'       => commit SQL batch waiting to be pushed
  #   - 'NNNN-season_board_backfill-<season>.sql' / 'NNNN-calendar_link-<cal>-<fin>.sql' /
  #     'NNNN-meeting_cancel-<meeting>.sql' / 'NNNN-calendar_cancel-<cal>.sql' (data health "Flag cancelled")
  #                                 => board SQL scripts waiting to be pushed (see #other_sql_paths)
  #   - any other '.sql' (team managers, merges, fixes, ...) => other SQL waiting to be pushed (#other_sql_paths)
  #   Only the Data-Fix COMMIT scripts are source SQL: the kind comes from the SQL Outbox registry
  #   (Ops::SqlScript.kinds_for, one query per build); unregistered files (or the ops DB missing) fall back
  #   to the name: BOARD_SQL_REGEXP => other, Outbox::Kinds.commit_name? ('-lt4'/'-l4' suffix) => commit.
  # - <data_dir>/results.done/<season>/ => archived (committed) sources & phase files
  # - <data_dir>/results.sent/<season>/ => pushed SQL batches ('NNNN-<base>-lt4.sql')
  # - <data_dir>/manifests/<season>/'manifest-<base>.pdf'      => manifest pending extraction
  # - <data_dir>/manifests.done/<season>/'manifest-<base>.pdf' => extracted manifests
  #
  # results.new files are probed in full (when small enough), results.done files with
  # bounded head/tail reads only. Nothing is cached: build a new instance to rescan.
  #
  class DiskIndex # rubocop:disable Metrics/ClassLength
    PHASE_REGEXP = /\A(?<stem>.+)-phase(?<phase>\d+)\.json\z/
    SQL_REGEXP = /\A\d+-(?<base>.+?)(?:-lt4)?\.sql\z/
    SKIPPED_JSON_REGEXP = /\.(orig(-\d+)?|committed)\.json\z/
    # SQL scripts written by SeasonBoard::Backfill, SeasonBoard::CalendarLinker & the 06 "Flag cancelled" (not sources).
    BOARD_SQL_REGEXP = /\A\d+-(season_board_backfill-\d+|calendar_link-\d+-\d+|meeting_cancel-\d+|calendar_cancel-\d+)\.sql\z/
    # Folders (under data_dir, each with a <season> subfolder) scanned by #build!:
    SEASON_FOLDERS = %w[results.new results.done results.sent manifests manifests.done].freeze

    attr_reader :season_id, :data_dir

    def self.default_data_dir
      Rails.root.join('crawler/data')
    end

    def initialize(season_id:, data_dir: self.class.default_data_dir, source_resolver: nil)
      @season_id = season_id.to_s
      @data_dir = Pathname.new(data_dir)
      @probe = SourceProbe.new(source_resolver: source_resolver || DataFix::SourceResolver.new)
    end

    # Hash of FIN event id (String) => Entry.
    def entries
      build! unless @entries
      @entries
    end

    # Entry for the FIN event id (String or Integer), or nil.
    def for(fin_event_id)
      entries[fin_event_id.to_s]
    end
    alias [] for

    def fin_event_ids
      entries.keys
    end

    # Entries (one per base) without FIN id that still have something pending
    # (sources/phase files/SQL in results.new or a manifest PDF to extract).
    def unmatched
      build! unless @unmatched
      @unmatched
    end

    # Non-commit SQL scripts of the season folder in results.new (board scripts, team managers, merges, ...),
    # waiting to be pushed: they never create a source entry.
    def other_sql_paths
      build! unless @other_sql_paths
      @other_sql_paths
    end
    alias board_sql_paths other_sql_paths

    # FIN event id read for a base name (or nil).
    def fin_event_id_for_base(base)
      build! unless @fin_ids_by_base
      @fin_ids_by_base[base]
    end

    def results_new_dir = data_dir.join('results.new', season_id)
    def results_done_dir = data_dir.join('results.done', season_id)
    def results_sent_dir = data_dir.join('results.sent', season_id)
    def manifests_dir = data_dir.join('manifests', season_id)
    def manifests_done_dir = data_dir.join('manifests.done', season_id)

    private

    # Raw scan per base: { new: { lt2:, lt4:, phases: {N => path} }, done: {...}, sql_new: [], sql_sent: [], pdf: [], pdf_done: [] }
    def build!
      @other_sql_paths = []
      @registry_kinds = registry_kinds
      @scan = Hash.new do |hash, base|
        hash[base] = { new: { phases: {} }, done: { phases: {} }, sql_new: [], sql_sent: [], pdf: [], pdf_done: [] }
      end
      scan_results_dir(results_new_dir, :new)
      scan_results_dir(results_done_dir, :done)
      scan_sql_dir(results_new_dir, :sql_new)
      scan_sql_dir(results_sent_dir, :sql_sent)
      scan_manifest_dir(manifests_dir, :pdf)
      scan_manifest_dir(manifests_done_dir, :pdf_done)

      @fin_ids_by_base = {}
      @entries = {}
      @unmatched = []
      @scan.keys.sort.each { |base| index_base(base, @scan[base]) }
      @scan = nil
    end

    def index_base(base, files)
      new_facts = source_facts(files[:new], full: true)
      done_facts = source_facts(files[:done], full: false)
      fin_id = (new_facts + done_facts).filter_map { |facts| facts[:fin_event_id] }.first
      @fin_ids_by_base[base] = fin_id

      entry = fin_id ? (@entries[fin_id] ||= Entry.new(fin_id)) : Entry.new(nil)
      entry.add_base(base)
      source = build_source(base, files[:new][:phases], new_facts)
      entry.sources << source if source
      fill_entry(entry, files, done_facts)
      @unmatched << entry if fin_id.nil? && entry.pending?
    end

    def fill_entry(entry, files, done_facts)
      done_facts.each do |facts|
        entry.archived_paths << facts[:path]
        entry.mark_archived_meeting_only! if facts[:meeting_only]
      end
      entry.sql_new_paths.concat(files[:sql_new].sort)
      entry.sql_sent_paths.concat(files[:sql_sent].sort)
      entry.manifest_pdf_paths.concat(files[:pdf].sort)
      entry.manifest_done_paths.concat(files[:pdf_done].sort)
    end

    def build_source(base, phases, facts)
      return nil if facts.empty? && phases.empty?

      lt2, lt4 = %i[lt2 lt4].map { |role| facts.find { |f| f[:role] == role } || {} }
      Source.new(
        base:, lt2_path: lt2[:path], lt4_path: lt4[:path],
        has_results: facts.any? { |f| f[:has_results] }, meeting_only: lt4.fetch(:meeting_only, false),
        phase: phases.keys.max, phase_paths: phases.sort.to_h,
        mtime: [lt2[:path], lt4[:path], *phases.values].compact.map { |path| File.mtime(path) }.max
      )
    end

    # Returns the facts of the LT2 & LT4 files of a base in a folder (LT2 first).
    def source_facts(dir_files, full:)
      [[:lt2, dir_files[:lt2]], [:lt4, dir_files[:lt4]]].filter_map do |role, path|
        @probe.call(path, full:).merge(role:, path:) if path
      end
    end

    # == Scanning

    def scan_results_dir(dir, where)
      each_file(dir) do |name, path|
        next if !name.end_with?('.json') || SKIPPED_JSON_REGEXP.match?(name)

        if (match = PHASE_REGEXP.match(name))
          @scan[match[:stem].delete_suffix('-lt4')][where][:phases][match[:phase].to_i] = path
        elsif name.end_with?('-lt4.json')
          @scan[name.delete_suffix('-lt4.json')][where][:lt4] = path
        else
          role = @probe.layout_type(path) == 4 ? :lt4 : :lt2
          # (a '-lt4.json' sibling wins over an LT4-content '<base>.json')
          @scan[name.delete_suffix('.json')][where][role] ||= path
        end
      end
    end

    def scan_sql_dir(dir, key)
      each_file(dir) do |name, path|
        next unless name.end_with?('.sql')

        match = SQL_REGEXP.match(name)
        if match && commit_sql?(name, path)
          @scan[match[:base]][key] << path
        elsif key == :sql_new
          @other_sql_paths << path
        end
      end
    end

    # True for a Data-Fix commit script (see the class notes).
    def commit_sql?(name, path)
      kind = @registry_kinds[relative_sql_path(path)]
      return kind == 'commit' if kind
      return false if BOARD_SQL_REGEXP.match?(name)

      Outbox::Kinds.commit_name?(name)
    end

    # Kinds of the registered SQL scripts of the season folders ({ rel_path => kind }, {} without the ops DB).
    def registry_kinds
      paths = [results_new_dir, results_sent_dir].flat_map { |dir| dir.directory? ? dir.glob('*.sql') : [] }
      return {} if paths.empty?

      Ops.safely({}) { Ops.available? ? Ops::SqlScript.kinds_for(paths.map { |path| relative_sql_path(path) }) : {} }
    end

    def relative_sql_path(path)
      Pathname.new(path).relative_path_from(data_dir).to_s
    end

    def scan_manifest_dir(dir, key)
      each_file(dir) do |name, path|
        @scan[name.sub(/\.pdf\z/i, '').delete_prefix('manifest-')][key] << path if name.downcase.end_with?('.pdf')
      end
    end

    def each_file(dir)
      return unless dir.directory?

      dir.children.sort.each do |child|
        yield(child.basename.to_s, child.to_s) if child.file?
      end
    end
  end
end
