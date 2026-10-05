# frozen_string_literal: true

require 'goggles_db'
require 'csv'

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR
#-- ---------------------------------------------------------------------------
#++

namespace :import do # rubocop:disable Metrics/BlockLength
  # Default Goggles::Season#id value for most tasks
  DEFAULT_SEASON_ID = 262 unless defined? DEFAULT_SEASON_ID
  #-- ---------------------------------------------------------------------------
  #++

  desc <<~DESC
    Reads standard timings from an XLSX or CSV source file.
    Converts each row to a StandardTiming and prepares the SQL script for data-import.

    Source files are stored under 'crawler/data/standard_timings' (possibly inside a
    '#{DEFAULT_SEASON_ID}'-like sub-folder named after the season ID).
    Output file will be stored in 'crawler/data/results.new'.

    Supported/expected column formats (with header row; either one is valid for CSV,
    XLSX sheets are auto-detected by their header labels):

    1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
       (XLSX: CATEG|CATEGORIA, COD GARA, GARA, SESSO, VASCA, CENTESIMI|CENT TOT,
        TEMPO (mmsscc), TEMPO PRINT - other columns are ignored)
    2. "category_code;event_label;25_m;50_m;25_f;50_f" (CSV only)

    Options: [season=season#id|<#{DEFAULT_SEASON_ID}>]
             [source=source_file_name|<auto-discovery>]

      - season: season ID, used also as sub-folder name for source file lookup.
      - source: source file name (with or without '.xlsx'/'.csv' extension), searched
                under 'crawler/data/standard_timings' and inside its <season_id> sub-folder.
                When not specified, the first file matching
                '*mst_tb_ind*<season.begin_year>*.xlsx' inside the <season_id> sub-folder
                is used (with fallbacks for legacy layouts and .csv files).

  DESC
  task standard_timings: :environment do # rubocop:disable Metrics/BlockLength
    puts "\r\n*** Import StandardTimings from file ***"
    puts "\r\nPlease make sure the source file has one of the supported formats:"
    puts ' - XLSX: sheets with header row "CATEG*|COD GARA|GARA|SESSO|VASCA|...|TEMPO PRINT"'
    puts ' - CSV:  1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"'
    puts '         2. "category_code;event_label;25_m;50_m;25_f;50_f"'
    puts ''

    season_id = ENV.include?('season') ? ENV['season'].to_i : DEFAULT_SEASON_ID
    season = GogglesDb::Season.find_by(id: season_id)
    if season.nil?
      puts('You need a valid Season ID to proceed.')
      exit
    end
    puts "--> Season #{season.id}, #{season.header_year}"

    filename = resolve_source_filename(season)
    if filename.nil?
      puts("Can't find a suitable source file under 'crawler/data/standard_timings' for season #{season.id}.")
      exit
    end
    puts "--> Source file: #{filename}"

    data = nil
    if File.extname(filename.to_s).casecmp('.xlsx').zero?
      extractor = Parser::StandardTimingXlsx.new(filename)
      begin
        data = extractor.rows
      rescue StandardError => e
        puts("Can't parse XLSX source: #{e.message}")
        exit
      end
      puts "--> Sheet(s) used: #{extractor.sheets_used.join(', ')}"
      extractor.warnings.each { |w| puts "    WARNING: #{w}" }
      puts "    (#{extractor.dupe_rows} duplicated rows skipped)" if extractor.dupe_rows.positive?
    else
      data = detect_csv_format(filename)
      if data.nil?
        puts('Unrecognized CSV format.')
        exit
      end
    end

    errors = check_data_validity(data, season)
    if errors.any?
      puts("\r\n*** #{errors.count} invalid reference(s) found - fix the source data (or the DB) then retry: ***")
      errors.each { |msg| puts "    - #{msg}" }
      exit
    end

    puts "--> Read #{data.size} rows. Processing..."
    puts "\r\n"
    sql_log = [
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      "\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";",
      'SET AUTOCOMMIT = 0;',
      "START TRANSACTION;\r\n"
    ]
    combo_codes = %w[25_m 50_m 25_f 50_f]

    data.each do |row|
      event_type_code = convert_event_label_to_code(row['event_label'])

      # Format 1: 1x SQL statement x csv row:
      if row['timing'].present?
        if row['timing'] == '-'
          putc '-'
          next
        end

        t = Parser::Timing.from_l2_result(row['timing'].to_s.strip)
        sql_log += add_insert_row(
          minutes: t.minutes, seconds: t.seconds, hundredths: t.hundredths,
          season_id:, gender: row['gender'].to_s.strip.upcase,
          category_code: row['category_code'].to_s.strip.upcase,
          event_type_code:, pool_type: row['pool_type'].to_s.strip
        )
        putc '.'

      # Format 2: 4x SQL statement x csv row using "combo codes" (4 different columns x group):
      elsif row['25_m'].present? && row['50_m'].present? && row['25_f'].present? && row['50_f'].present?
        combo_codes.each do |combo_code|
          if row[combo_code].to_s.strip.blank? || row[combo_code].to_s.strip == '-'
            putc '-'
            next
          end

          pool_type = combo_code.split('_').first
          gender = combo_code.split('_').last.upcase
          t = Parser::Timing.from_l2_result(row[combo_code].to_s.strip)
          sql_log += add_insert_row(
            minutes: t.minutes, seconds: t.seconds, hundredths: t.hundredths,
            season_id:, gender:, category_code: row['category_code'].to_s.strip.upcase, event_type_code:, pool_type:
          )
          putc '.'
        end
      end
    end
    sql_log << "\r\nCOMMIT;\r\n"
    puts "\r\n"

    sql_file_name = "#{SCRIPT_OUTPUT_DIR}/000-#{season_id}-standard_timings.sql"
    File.open(sql_file_name, 'w+') { |f| f.puts(sql_log.join("\r\n")) }
    puts("\r\nFile '#{sql_file_name}' saved.")
  end

  private

  # Returns the full path of the source file to be processed, or nil if not found.
  #
  # When the 'source' ENV option is given, the file is searched under
  # 'crawler/data/standard_timings' and its <season_id> sub-folder, with or
  # without the '.xlsx'/'.csv' extension (XLSX preferred).
  #
  # Otherwise, the first file matching '*mst_tb_ind*<season.begin_year>*.xlsx'
  # inside the <season_id> sub-folder is used; when none is found, the same
  # pattern is tried inside any '*<season_id>*' sub-folder (for legacy combined
  # folders like '232-242'), then directly under 'standard_timings', and finally
  # the same patterns are repeated for '.csv' files (with the legacy flat
  # '<season_id>-mst_tb_ind_<b>-<e>.csv' name as last resort).
  def resolve_source_filename(season) # rubocop:disable Rake/MethodDefinitionInTask,Metrics/AbcSize
    base_dir = Rails.root.join('crawler/data/standard_timings')
    if ENV['source'].present?
      source = ENV['source'].sub(/\.(csv|xlsx)\z/i, '')
      candidates = [
        base_dir.join("#{source}.xlsx"),
        base_dir.join("#{source}.csv"),
        base_dir.join(season.id.to_s, "#{source}.xlsx"),
        base_dir.join(season.id.to_s, "#{source}.csv")
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
  def check_data_validity(rows, season) # rubocop:disable Rake/MethodDefinitionInTask,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    errors = []
    checkable = rows.select { |row| meaningful_timing_row?(row) }

    category_codes = checkable.map { |row| row['category_code'].to_s.strip }.compact_blank.uniq
    found_codes = GogglesDb::CategoryType.where(season_id: season.id, code: category_codes).pluck(:code)
    errors += (category_codes - found_codes).sort.map do |code|
      "category_code '#{code}' not found among CategoryTypes for season #{season.id}"
    end

    event_codes = checkable.map { |row| convert_event_label_to_code(row['event_label']) }.compact_blank.uniq
    found_events = GogglesDb::EventType.where(code: event_codes).pluck(:code)
    errors += (event_codes - found_events).sort.map do |code|
      "unknown event_type code '#{code}' (from event_label)"
    end

    gender_codes = checkable.map { |row| row['gender'].to_s.strip.upcase }.compact_blank.uniq
    errors += (gender_codes - %w[M F]).sort.map { |code| "unknown gender code '#{code}'" }

    pool_codes = checkable.map { |row| row['pool_type'].to_s.strip }.compact_blank.uniq
    errors += (pool_codes - %w[25 50]).sort.map { |code| "unknown pool_type code '#{code}'" }

    errors
  end

  # Returns true when the row would produce at least one SQL statement
  # (a valid timing either in the 'timing' column or in any combo column).
  def meaningful_timing_row?(row) # rubocop:disable Rake/MethodDefinitionInTask
    timing = row['timing'].to_s.strip
    return true if timing.present? && timing != '-'

    %w[25_m 50_m 25_f 50_f].any? do |col|
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
  def detect_csv_format(filename) # rubocop:disable Rake/MethodDefinitionInTask,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    csv = CSV.parse(File.read(filename), headers: true) # col_sep: ',' (default)
    return csv if csv.headers.include?('timing')

    csv = CSV.parse(File.read(filename), headers: true, col_sep: ';')
    return csv if csv.headers.include?('timing')

    csv = CSV.parse(File.read(filename), headers: true) # col_sep: ',' (default)
    return csv if csv.headers.include?('25_m') && csv.headers.include?('50_m') && csv.headers.include?('25_f') && csv.headers.include?('50_f')

    csv = CSV.parse(File.read(filename), headers: true, col_sep: ';')
    return csv if csv.headers.include?('25_m') && csv.headers.include?('50_m') && csv.headers.include?('25_f') && csv.headers.include?('50_f')

    nil
  end

  # Returns the EventType code for the specified event label.
  def convert_event_label_to_code(event_label) # rubocop:disable Rake/MethodDefinitionInTask
    event_label.to_s.strip.squeeze(' ').upcase
               .gsub(' STILE LIBERO', 'SL')
               .gsub(' DORSO', 'DO')
               .gsub(' RANA', 'RA')
               .gsub(' FARFALLA', 'FA')
               .gsub(' MISTI', 'MI')
  end

  # Returns a list of text strings composing a single SQL INSERT statement for the resulting SQL script.
  # == Supported options:
  # - season_id: Season ID.
  # - gender: GenderType code ('M'/'F').
  # - category_code: CategoryType code ('M25', 'M30', ...).
  # - event_type_code: EventType code ('50SL', '50DO', ...).
  # - pool_type: PoolType code ('25'/'50').
  # - minutes: the stadard timing minutes.
  # - seconds: the standard timing seconds.
  # - hundredths: the standard timing hundredths.
  # == Returns:
  # An Array of composable strings for the SQL INSERT statement.
  def add_insert_row(options = {}) # rubocop:disable Rake/MethodDefinitionInTask
    gender_type_id = options[:gender] == 'F' ? GogglesDb::GenderType::FEMALE_ID : GogglesDb::GenderType::MALE_ID
    pool_type_id = options[:pool_type] == '50' ? GogglesDb::PoolType::MT_50_ID : GogglesDb::PoolType::MT_25_ID
    # NOTE: relying on the more generic SQL sub-select like...
    #   "(select t.id from category_types t where t.code = '#{options[:category_code]}' AND t.season_id = #{options[:season_id]})"
    # ...Won't spot early data misalignments between DBs. Also, using direct IDs for subentities makes the ~1100 queries faster.
    category_type_id = GogglesDb::CategoryType.where(season_id: options[:season_id], code: options[:category_code]).first&.id
    raise "Can't find category_type_id for season #{options[:season_id]} and code '#{options[:category_code]}'" if category_type_id.blank?

    event_type_id = GogglesDb::EventType.where(code: options[:event_type_code]).first&.id
    raise "Can't find event_type_id with code '#{options[:event_type_code]}'" if event_type_id.blank?

    [
      'INSERT INTO standard_timings (minutes,seconds,hundredths, season_id, gender_type_id, category_type_id, event_type_id, pool_type_id, created_at, updated_at)',
      "  VALUES (#{options[:minutes]}, #{options[:seconds]}, #{options[:hundredths]}, #{options[:season_id]}, #{gender_type_id}, " \
      "#{category_type_id}, #{event_type_id}, #{pool_type_id}, NOW(), NOW());"
    ]
  end
end
