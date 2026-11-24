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

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-import_categories-<src_id>-<dest_id>.sql'

    (Since phase 13: the 'categories.clone' operation, a repair step of the season-start checklist.)

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
    status = Maintenance::RakeRunner.call('import:categories', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
