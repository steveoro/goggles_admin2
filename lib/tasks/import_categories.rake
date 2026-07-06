# frozen_string_literal: true

require 'fileutils'

#
# = Local Data import helper tasks
#
#   - (p) FASAR Software 2007-2026
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR
#-- ---------------------------------------------------------------------------
#++

namespace :import do
  desc <<~DESC
      Generates a replayable SQL script that clones missing CategoryType rows from a
    source Season to a destination Season, optionally removing unwanted categories
    from the destination first.

    Both seasons must already exist in the database.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/<index>-import_categories-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_season_id>
             dest=<destination_season_id>
             [index=<auto>] [simulate='0'|<'1'>]
             [remove=<comma_separated_category_codes>]

      - index: a progressive number for the generated file;
      - src: source Season ID (must exist);
      - dest: destination Season ID (must exist);

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - remove: optional comma-separated list of category codes to DELETE from the
        destination season before cloning (e.g. remove=U25,U30).

  DESC
  task(categories: ['merge:check_needed_dirs']) do
    puts '*** Task: import:categories ***'
    src_season = GogglesDb::Season.find_by(id: ENV['src'].to_i)
    dest_season = GogglesDb::Season.find_by(id: ENV['dest'].to_i)
    if src_season.nil? || dest_season.nil?
      puts("You need to have both 'src' & 'dest' IDs with valid Season values in order to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    remove_codes = ENV['remove'].present? ? ENV['remove'].split(',').map(&:strip).compact_blank : []

    puts("\r\nCloning CategoryTypes from Season #{src_season.id} (#{src_season.header_year})")
    puts("    |=> Season #{dest_season.id} (#{dest_season.header_year})")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- remove_codes...: #{remove_codes.any? ? remove_codes.join(', ') : '(none)'}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    cloner = Import::CategoryCloner.new(src_season:, dest_season:, remove_codes:)
    cloner.prepare

    puts("\r\n*** Log: ***\r\n")
    puts(cloner.log.join("\r\n"))

    if cloner.errors.present?
      puts("\r\n*** Errors: ***\r\n")
      puts(cloner.errors.join("\r\n"))
      puts('Aborted.')
      exit
    end

    file_name = "#{format('%04d', file_index)}-import_categories-#{src_season.id}-#{dest_season.id}"
    process_sql_file(file_name:, sql_log_array: cloner.sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
