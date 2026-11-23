# frozen_string_literal: true

require 'fileutils'

#
# = Local SQL helper tasks
#
#   - (p) FASAR Software 2007-2024
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :db do
  desc <<~DESC
      Runs the specified SQL script (or scripts) on localhost.
    The Rails.env will set the destination DB for script execution on localhost.

    Options: [Rails.env=#{Rails.env}]
             path=<full_pathname>

      - path: the full path to the SQL script file to be executed; wildcards are supported.
              (e.g.: '/path/to/*.sql' => runs all '.sql' files in the given path,
              without recursion in subdirectories.)

  DESC
  task(run: :environment) do
    puts '*** Task: db:run ***'
    full_pathname = ENV.fetch('path', nil)
    if full_pathname.nil?
      puts('You need to have valid full pathname to the script that has to be executed.')
      exit
    end
    puts("All scripts will be executed on localhost using '#{Rails.env}' DB.")

    Dir[full_pathname].select { |path| File.file?(path) }.each do |file_path|
      puts("\r\n--> '#{file_path}'")
      # (also tells the Outbox registry: a held script becomes pushable, in local-apply order)
      execute_sql_file(full_pathname: file_path)
    end
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  # Runs the specified SQL script on localhost with the MariaDB client (LocalDb::SqlRunner: wrapped in an outer
  # transaction, password passed through MYSQL_PWD, never on the command line), then tells the SQL Outbox:
  # - success => Outbox::Writer.mark_applied_locally! (a held script becomes pending, re-sequenced when needed);
  # - failure => Outbox::Writer.mark_apply_failed! (held, 'local_apply_failed') and the task exits with 1.
  # Scripts outside the Outbox scan roots (or with the ops DB missing) are just run.
  #
  # == Params:
  # - full_pathname: the full pathname of the SQL script file.
  #
  def execute_sql_file(full_pathname:) # rubocop:disable Rake/MethodDefinitionInTask
    puts('--> Executing script...')
    data_root = Outbox.data_root_for(full_pathname)
    result = LocalDb::SqlRunner.call(path: full_pathname)
    if result.success?
      script = Outbox::Writer.mark_applied_locally!(full_pathname, data_root:)
      puts("--> Done in #{result.duration.round(2)} s#{" (Outbox: #{script.state}, seq #{script.seq})" if script}.")
      return result
    end

    Outbox::Writer.mark_apply_failed!(full_pathname, error: result.stderr, data_root:)
    puts(result.stderr)
    puts("\r\n*** ERROR: Script execution failed. Transaction rolled back. ***")
    exit 1
  end
  #-- -------------------------------------------------------------------------
  #++
end
