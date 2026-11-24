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

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-normalize_coded_names.sql'
        (registered in the SQL Outbox: HELD until applied locally, unless simulate=0;
        since phase 13 a batch without any change writes no file: 'coded_names.normalize')

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
    status = Maintenance::RakeRunner.call('normalize:coded_names', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
