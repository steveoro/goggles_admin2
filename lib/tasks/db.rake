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
      execute_sql_file(full_pathname: file_path)
    end
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  # Runs the specified SQL script on localhost using the MySQL client.
  # Credentials are taken directly from the Rails environment configuration.
  # No checking is performed on the script content.
  #
  # == Params:
  # - file_name: the full pathname of the SQL script file.
  #
  def execute_sql_file(full_pathname:) # rubocop:disable Rake/MethodDefinitionInTask
    puts('--> Executing script...')
    # NOTE: for security reasons, ActiveRecord::Base.connection.execute() executes just the first
    # command when passed multiple staments. This is somewhat overlooked and not properly documented
    # in the docs as of this writing. We'll use the MySql client for this one:
    rails_config = Rails.configuration
    db_name      = rails_config.database_configuration[Rails.env]['database']
    db_user      = rails_config.database_configuration[Rails.env]['username']
    db_pwd       = rails_config.database_configuration[Rails.env]['password']
    db_host      = rails_config.database_configuration[Rails.env]['host']
    system("mysql --host=#{db_host} --user=#{db_user} --password=\"#{db_pwd}\" --database=#{db_name} --execute=\"\\. #{full_pathname}\"")
  end
  #-- -------------------------------------------------------------------------
  #++
end
