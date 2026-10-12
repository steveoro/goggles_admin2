# frozen_string_literal: true

require 'fileutils'

#
# = Local Data normalization helper tasks
#
#   - (p) FASAR Software 2007-2024
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :normalize do
  # NOTE: the goggles_db engine defines a same-named task that applies the changes
  # directly to the DB. Inside goggles_admin2 the task must only *export* a SQL batch
  # file, so the engine's action is cleared first to prevent it from running as well.
  Rake::Task['normalize:coded_names'].clear if Rake::Task.task_defined?('normalize:coded_names')

  desc <<~DESC
      Normalizes all coded names (Meeting#code & SwimmingPool#nick_name) using the
    shared Normalizer helpers from goggles_db, generating a single-transaction
    SQL batch file that can be pushed to the remote production server using the
    Admin UI (see the 'results.new' tab in the data-import push dashboard).

    For Meetings, this will detect & fix also the edition and the edition_type
    (for recurring Championship meetings of the FIN/LEN/FINA federations).

    Unlike the engine-side task of the same name (which updates the DB directly),
    this task DOES NOT apply any change to the localhost DB: it just writes the
    script. The localhost DB is assumed to be in-sync with the remote production DB,
    so the generated UPDATEs are issued on the row IDs found locally.

    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/normalize/<index>-normalize_coded_names.sql'

    Options: [Rails.env=#{Rails.env}]
             [limit=N|<0>] [index=<auto>]
             [simulate='0'|<'1'>]

      - limit: when positive, only the first N rows of each domain will be processed
               (default 0: all rows);

      - index: an override index for the generated file (default: <auto>);

      - simulate: when set to '0' the generated script will also be executed on
                  localhost (useful to keep the local DB in-sync with remote after
                  the push; toggled off by default).

  DESC
  task(coded_names: ['merge:check_needed_dirs']) do
    puts '*** Task: normalize:coded_names ***'
    limit_rows = ENV.include?('limit') ? ENV['limit'].to_i : 0
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir('normalize')
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested

    puts("\r\n- limit..........: #{limit_rows.positive? ? limit_rows : '(all rows)'}")
    puts("- simulate.......: #{simulate}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}/normalize\r\n")

    normalizer = Normalize::CodedNames.new(limit: limit_rows)
    normalizer.call

    puts("\r\n*** Change log: ***\r\n")
    puts(normalizer.change_log.join("\r\n"))
    if normalizer.duplicate_pool_ids.present?
      puts("\r\nWARNING: found already existing coded names in SwimmingPool IDs #{normalizer.duplicate_pool_ids.inspect}")
      puts('(those rows were skipped in the script; a manual fix is required)')
    end
    puts("\r\n-- Stats: meetings scanned #{normalizer.stats[:meetings_scanned]}, updated #{normalizer.stats[:meetings_updated]}; " \
         "pools scanned #{normalizer.stats[:pools_scanned]}, updated #{normalizer.stats[:pools_updated]}")

    file_name = "#{format('%04d', file_index)}-normalize_coded_names"
    process_sql_file(
      file_name:,
      sql_log_array: normalizer.single_transaction_sql_log,
      subdir: 'normalize',
      simulate:
    )
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
