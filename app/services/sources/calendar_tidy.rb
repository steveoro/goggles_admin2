# frozen_string_literal: true

module Sources
  #
  # = Sources::CalendarTidy
  #
  # Tidies the calendar folder of a season (0.10.104): moves from 'calendar.new/<season>' to 'calendar.done/<season>'
  # (never deletes):
  #
  # - :calendar_superseded  an original calendar CSV ('<YYYYMMDD>-<kind>.csv', kind e.g. '262-2-FIN-calendar' or
  #                         '262-3-FIN-current-meetings') superseded by a newer original of the same kind in either
  #                         folder (by the name date, then the mtime: SeasonBoard::CalendarIndex's order). The newest
  #                         original of each kind never moves, so the 'Eventi' calendar CalendarIndex reads stays the
  #                         same (it reads both folders);
  # - :calendar_selection   a '-sel-' subset written by "Select meetings" whose crawl is over (no busy activity entry
  #                         names it: the crawler itself moves the subset it crawled);
  # - :calendar_leftover    a '-skip.csv' leftover (the rows a calendar crawl skipped: they are on the Season board).
  #
  # Never a file younger than Sources::Cleanup::MIN_AGE or named by a busy activity entry (Sources::Cleanup::Safety);
  # a name already in calendar.done keeps the file in place unless both copies are identical (then it goes to the
  # duplicates folder of the run backup folder).
  #
  # Run at the end of the calendar crawls of the Sources crawler tab (Sources::CrawlTidy) and by the clean-up page
  # (Sources::Cleanup::Plan / Apply, rule (c)).
  #
  class CalendarTidy
    ORIGINAL_REGEXP = /\A(?<date>\d{8})-(?<kind>.+)\.csv\z/
    SUBSET_REGEXP = Sources::Index::Calendars::SUBSET_REGEXP
    LEFTOVER_REGEXP = Sources::Index::Calendars::LEFTOVER_REGEXP
    RULES = %i[calendar_superseded calendar_selection calendar_leftover].freeze

    # A file selected by a rule: path (absolute), rule, refusal reason (nil when it can move), collision with
    # calendar.done (nil, :identical or :different).
    Candidate = Data.define(:path, :rule, :refusal, :collision) do
      def movable? = refusal.nil?
    end

    attr_reader :season_id, :safety

    # - mover: a Sources::Cleanup::Mover (default: a new one with its own RunFolder, i.e. MOVES.txt).
    def initialize(season_id:, data_root: Sources.data_root, safety: nil, mover: nil)
      @season_id = season_id.to_i
      @data_root = Pathname.new(data_root)
      @safety = safety || Cleanup::Safety.new(season_id:, data_root:)
      @mover = mover || Cleanup::Mover.new(guard: @safety.guard, run_folder: Cleanup::RunFolder.new(root: @safety.guard.root, season_id:))
    end

    def new_dir = @data_root.join('calendar.new', season_id.to_s)
    def done_dir = @data_root.join('calendar.done', season_id.to_s)

    # Every rule-selected file with its refusal / collision (read-only).
    def candidates
      @candidates ||= selected.map do |path, rule|
        refusal = @safety.file_refusal(path)
        collision = refusal ? nil : @mover.collision(path, done_dir)
        Candidate.new(path: path.to_s, rule:, refusal: refusal || (:name_collision if collision == :different), collision:)
      end
    end

    # Moves the movable candidates (re-checked by the Mover; an identical copy already in calendar.done goes to the
    # 'duplicates/calendar.new' subfolder of the run backup folder). Returns the Mover outcomes.
    def call
      candidates.select(&:movable?).map { |candidate| @mover.call(candidate.path, dir: done_dir, duplicate_origin: 'calendar.new') }
    end

    private

    # [[Pathname, rule]] of the files the rules select, sorted by name.
    def selected
      files = csv_files(new_dir)
      newest = newest_by_kind(files + csv_files(done_dir))
      files.filter_map do |path|
        name = path.basename.to_s
        if LEFTOVER_REGEXP.match?(name) then [path, :calendar_leftover]
        elsif SUBSET_REGEXP.match?(name) then [path, :calendar_selection]
        elsif (match = ORIGINAL_REGEXP.match(name)) && newest[match[:kind]] != path then [path, :calendar_superseded]
        end
      end
    end

    # { kind => Pathname of the newest original of that kind }.
    def newest_by_kind(paths)
      originals = paths.filter_map do |path|
        name = path.basename.to_s
        next if LEFTOVER_REGEXP.match?(name) || SUBSET_REGEXP.match?(name)

        match = ORIGINAL_REGEXP.match(name)
        [match[:kind], [match[:date], mtime(path)], path] if match
      end
      originals.group_by(&:first).transform_values { |list| list.max_by { |item| item[1] }.last }
    end

    def csv_files(dir)
      dir.directory? ? dir.children.select { |path| path.extname.casecmp?('.csv') && (path.file? || path.symlink?) }.sort : []
    end

    def mtime(path)
      File.mtime(path).to_f
    rescue SystemCallError
      0.0
    end
  end
end
