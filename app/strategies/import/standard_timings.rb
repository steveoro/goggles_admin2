# frozen_string_literal: true

require 'csv'

module Import
  #
  # = Import::StandardTimings
  #
  # Reads the standard timings of a season from an XLSX (Parser::StandardTimingXlsx, unchanged) or CSV source file and
  # builds the single-transaction SQL script inserting them (the code of 'import:standard_timings' before phase 13,
  # unchanged: same source discovery, same validity checks, same rows). Never touches the DB: the script is applied
  # by the 'standard_timings.import' operation (Maintenance::Executor).
  #
  # == Usage
  #   importer = Import::StandardTimings.new(season:, source: nil).call { |event, value| ... }
  #   importer.errors      # => [] or the messages that stopped it (no SQL then; #validity_errors: the invalid references)
  #   importer.sql_log     # => the script lines
  #
  # #call yields its progress, in the order the rake task printed it:
  #   :source (path), :sheets (names), :warning (text), :dupes (count), :read (rows count), :row ('.' or '-').
  #
  class StandardTimings # rubocop:disable Metrics/ClassLength
    BASE_DIR = Rails.root.join('crawler/data/standard_timings')
    COMBO_CODES = %w[25_m 50_m 25_f 50_f].freeze

    attr_reader :season, :source, :base_dir, :filename, :rows, :sheets_used, :warnings, :dupe_rows, :errors, :sql_log,
                :inserts_count, :skipped_count, :validity_errors

    # == Params
    # - season: GogglesDb::Season (required);
    # - source: source file name (with or without '.xlsx'/'.csv'), searched under +base_dir+ and its <season_id>
    #   sub-folder; nil: auto-discovery ('*mst_tb_ind*<begin year>*.xlsx', with the legacy fallbacks);
    # - base_dir: the standard timings folder (default crawler/data/standard_timings).
    def initialize(season:, source: nil, base_dir: BASE_DIR)
      raise(ArgumentError, 'season must be a Season!') unless season.is_a?(GogglesDb::Season)

      @season = season
      @source = source.presence
      @base_dir = Pathname.new(base_dir)
      @errors = []
      @validity_errors = []
      @warnings = []
      @sheets_used = []
      @dupe_rows = 0
      @sql_log = []
      @inserts_count = 0
      @skipped_count = 0
    end

    # Resolves the source, reads and checks the rows, then builds #sql_log (only when no error was found).
    # Returns self.
    def call(&progress)
      progress ||= ->(*) {}
      @filename = resolve_source_filename
      return fail_with("Can't find a suitable source file under 'crawler/data/standard_timings' for season #{season.id}.") if @filename.nil?

      progress.call(:source, @filename)
      @rows = read_rows(progress)
      return self if @errors.any?

      @validity_errors = check_data_validity(@rows)
      @errors = @validity_errors.dup
      return self if @errors.any?

      progress.call(:read, @rows.size)
      build_sql_log(progress)
      self
    end

    # Returns the full path of the source file to be processed, or nil if not found.
    #
    # When a +source+ is given, the file is searched under +base_dir+ and its <season_id> sub-folder, with or
    # without the '.xlsx'/'.csv' extension (XLSX preferred).
    #
    # Otherwise, the first file matching '*mst_tb_ind*<season.begin_year>*.xlsx' inside the <season_id> sub-folder is
    # used; when none is found, the same pattern is tried inside any '*<season_id>*' sub-folder (for legacy combined
    # folders like '232-242'), then directly under +base_dir+, and finally the same patterns are repeated for '.csv'
    # files (with the legacy flat '<season_id>-mst_tb_ind_<b>-<e>.csv' name as last resort).
    def resolve_source_filename # rubocop:disable Metrics/AbcSize
      if source
        name = source.sub(/\.(csv|xlsx)\z/i, '')
        candidates = [
          base_dir.join("#{name}.xlsx"), base_dir.join("#{name}.csv"),
          base_dir.join(season.id.to_s, "#{name}.xlsx"), base_dir.join(season.id.to_s, "#{name}.csv")
        ]
        return candidates.find { |path| File.file?(path) }
      end

      glob = "*mst_tb_ind*#{season.begin_date.year}*"
      candidates = [
        *Dir.glob(base_dir.join(season.id.to_s, "#{glob}.{xlsx,XLSX}")),
        *Dir.glob(base_dir.join("*#{season.id}*", "#{glob}.{xlsx,XLSX}")),
        *Dir.glob(base_dir.join("#{glob}.{xlsx,XLSX}")),
        *Dir.glob(base_dir.join(season.id.to_s, "#{glob}.{csv,CSV}")),
        base_dir.join("#{season.id}-mst_tb_ind_#{season.begin_date.year}-#{season.end_date.year}.csv")
      ]
      candidates.find { |path| File.file?(path) }
    end

    # Validates all data references BEFORE any SQL is written.
    # Returns an Array of error messages (empty when everything checks out).
    def check_data_validity(rows) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      errors = []
      checkable = rows.select { |row| meaningful_timing_row?(row) }

      category_codes = checkable.map { |row| row['category_code'].to_s.strip }.compact_blank.uniq
      found_codes = GogglesDb::CategoryType.where(season_id: season.id, code: category_codes).pluck(:code)
      errors += (category_codes - found_codes).sort.map do |code|
        "category_code '#{code}' not found among CategoryTypes for season #{season.id}"
      end

      event_codes = checkable.map { |row| self.class.event_label_to_code(row['event_label']) }.compact_blank.uniq
      found_events = GogglesDb::EventType.where(code: event_codes).pluck(:code)
      errors += (event_codes - found_events).sort.map { |code| "unknown event_type code '#{code}' (from event_label)" }

      gender_codes = checkable.map { |row| row['gender'].to_s.strip.upcase }.compact_blank.uniq
      errors += (gender_codes - %w[M F]).sort.map { |code| "unknown gender code '#{code}'" }

      pool_codes = checkable.map { |row| row['pool_type'].to_s.strip }.compact_blank.uniq
      errors += (pool_codes - %w[25 50]).sort.map { |code| "unknown pool_type code '#{code}'" }

      errors
    end

    # Returns the EventType code for the specified event label.
    def self.event_label_to_code(event_label)
      event_label.to_s.strip.squeeze(' ').upcase
                 .gsub(' STILE LIBERO', 'SL')
                 .gsub(' DORSO', 'DO')
                 .gsub(' RANA', 'RA')
                 .gsub(' FARFALLA', 'FA')
                 .gsub(' MISTI', 'MI')
    end

    private

    def fail_with(message)
      @errors = [message]
      self
    end

    # The rows of the XLSX or CSV source (nil with an error when unreadable).
    def read_rows(progress)
      return read_csv_rows unless File.extname(@filename.to_s).casecmp('.xlsx').zero?

      extractor = Parser::StandardTimingXlsx.new(@filename)
      begin
        data = extractor.rows
      rescue StandardError => e
        fail_with("Can't parse XLSX source: #{e.message}")
        return
      end
      @sheets_used = extractor.sheets_used
      @warnings = extractor.warnings
      @dupe_rows = extractor.dupe_rows
      progress.call(:sheets, @sheets_used)
      @warnings.each { |warning| progress.call(:warning, warning) }
      progress.call(:dupes, @dupe_rows) if @dupe_rows.positive?
      data
    end

    def read_csv_rows
      data = detect_csv_format(@filename)
      fail_with('Unrecognized CSV format.') if data.nil?
      data
    end

    # Returns true when the row would produce at least one SQL statement
    # (a valid timing either in the 'timing' column or in any combo column).
    def meaningful_timing_row?(row)
      timing = row['timing'].to_s.strip
      return true if timing.present? && timing != '-'

      COMBO_CODES.any? do |col|
        value = row[col].to_s.strip
        value.present? && value != '-'
      end
    end

    # Returns the parsed CSV if any, nil otherwise.
    # Supported/expected column formats (with first row as header, either one is valid):
    #
    # 1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
    # 2. "category_code;event_label;25_m;50_m;25_f;50_f"
    #
    def detect_csv_format(filename)
      text = File.read(filename)
      formats = [->(headers) { headers.include?('timing') }, ->(headers) { (COMBO_CODES - headers).empty? }]
      formats.product([',', ';']).each do |format, col_sep|
        csv = CSV.parse(text, headers: true, col_sep:)
        return csv if format.call(csv.headers)
      end
      nil
    end

    def build_sql_log(progress) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      @sql_log = [
        # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
        "\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";",
        'SET AUTOCOMMIT = 0;',
        "START TRANSACTION;\r\n"
      ]
      @rows.each do |row|
        event_type_code = self.class.event_label_to_code(row['event_label'])

        # Format 1: 1x SQL statement x csv row:
        if row['timing'].present?
          if row['timing'] == '-'
            skip_row(progress)
            next
          end

          add_insert_row(progress, timing: row['timing'], gender: row['gender'].to_s.strip.upcase,
                                   category_code: row['category_code'].to_s.strip.upcase, event_type_code:,
                                   pool_type: row['pool_type'].to_s.strip)

        # Format 2: 4x SQL statement x csv row using "combo codes" (4 different columns x group):
        elsif COMBO_CODES.all? { |code| row[code].present? }
          COMBO_CODES.each do |combo_code|
            if row[combo_code].to_s.strip.blank? || row[combo_code].to_s.strip == '-'
              skip_row(progress)
              next
            end

            add_insert_row(progress, timing: row[combo_code], gender: combo_code.split('_').last.upcase,
                                     category_code: row['category_code'].to_s.strip.upcase, event_type_code:,
                                     pool_type: combo_code.split('_').first)
          end
        end
      end
      @sql_log << "\r\nCOMMIT;\r\n"
    end

    def skip_row(progress)
      @skipped_count += 1
      progress.call(:row, '-')
    end

    # Adds the two text lines of a single SQL INSERT statement (direct ids, as the rake task did: a misaligned
    # category or event type raises).
    def add_insert_row(progress, timing:, gender:, category_code:, event_type_code:, pool_type:) # rubocop:disable Metrics/ParameterLists
      parsed = Parser::Timing.from_l2_result(timing.to_s.strip)
      gender_type_id = gender == 'F' ? GogglesDb::GenderType::FEMALE_ID : GogglesDb::GenderType::MALE_ID
      pool_type_id = pool_type == '50' ? GogglesDb::PoolType::MT_50_ID : GogglesDb::PoolType::MT_25_ID
      # NOTE: relying on the more generic SQL sub-select like...
      #   "(select t.id from category_types t where t.code = '<code>' AND t.season_id = <id>)"
      # ...Won't spot early data misalignments between DBs. Also, using direct IDs for subentities makes the ~1100 queries faster.
      category_type_id = GogglesDb::CategoryType.where(season_id: season.id, code: category_code).first&.id
      raise "Can't find category_type_id for season #{season.id} and code '#{category_code}'" if category_type_id.blank?

      event_type_id = GogglesDb::EventType.where(code: event_type_code).first&.id
      raise "Can't find event_type_id with code '#{event_type_code}'" if event_type_id.blank?

      @sql_log += [
        'INSERT INTO standard_timings (minutes,seconds,hundredths, season_id, gender_type_id, category_type_id, event_type_id, pool_type_id, ' \
        'created_at, updated_at)',
        "  VALUES (#{parsed.minutes}, #{parsed.seconds}, #{parsed.hundredths}, #{season.id}, #{gender_type_id}, " \
        "#{category_type_id}, #{event_type_id}, #{pool_type_id}, NOW(), NOW());"
      ]
      @inserts_count += 1
      progress.call(:row, '.')
    end
  end
end
