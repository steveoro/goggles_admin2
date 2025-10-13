# frozen_string_literal: true

require 'goggles_db'
require 'csv'

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR
#-- ---------------------------------------------------------------------------
#++

namespace :import do # rubocop:disable Metrics/BlockLength
  # Default Goggles::Season#id value for most tasks
  DEFAULT_SEASON_ID = 252 unless defined? DEFAULT_SEASON_ID
  #-- ---------------------------------------------------------------------------
  #++

  desc <<~DESC
    Reads standard timings from the specified CSV file.
    Converts each row to a StandardTiming and prepares the SQL script for data-import.

    Source file is expected to be stored in 'crawler/data/standard_timings'.
    Output file will be stored in 'crawler/data/results.new'.

    Supported/expected column formats (with first row as header, either one is valid):

    1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
    2. "category_code;event_label;25_m;50_m;25_f;50_f"

    Options: [season=season#id|<#{DEFAULT_SEASON_ID}>]
             [source=csv_file_name|<'{season_id}-mst_tb_ind_{begin_date.year}-{end_date.year}'>]

      - season: season ID used as sub-folder for storing the individual JSON result files.
      - source: source file name without extension; this will be searched from 'crawler/data/standard_timings'

  DESC
  task standard_timings: :environment do # rubocop:disable Metrics/BlockLength
    puts "\r\n*** Import StandardTimings from CSV file ***"
    puts "\r\nPlease make sure the CSV has any of the supported column formats and has a valid column separator (',' or ';'):"
    puts ' 1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"'
    puts ' 2. "category_code;event_label;25_m;50_m;25_f;50_f"'
    puts ''

    season_id = ENV.include?('season') ? ENV['season'].to_i : DEFAULT_SEASON_ID
    season = GogglesDb::Season.find_by(id: season_id)
    if season.nil?
      puts('You need a valid Season ID to proceed.')
      exit
    end

    puts "--> Season #{season.id}, #{season.header_year}"
    source = ENV.include?('source') ? ENV['source'] : "#{season_id}-mst_tb_ind_#{season.begin_date.year}-#{season.end_date.year}"
    filename = Rails.root.join("crawler/data/standard_timings/#{source}.csv")
    csv = detect_csv_format(filename)
    if csv.nil?
      puts('Unrecognized CSV format.')
      exit
    end

    puts "--> Read #{csv.size} rows. Processing..."
    puts "\r\n"
    sql_log = [
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      "\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";",
      'SET AUTOCOMMIT = 0;',
      "START TRANSACTION;\r\n"
    ]
    combo_codes = %w[25_m 50_m 25_f 50_f]

    csv.each do |row|
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
          season_id:, gender: row['gender'],
          category_code: row['category_code'],
          event_type_code:, pool_type: row['pool_type']
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
            season_id:, gender:, category_code: row['category_code'], event_type_code:, pool_type:
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
    event_label.to_s.gsub(' STILE LIBERO', 'SL')
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
