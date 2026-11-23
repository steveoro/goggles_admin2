# frozen_string_literal: true

require 'open3'

module LocalDb
  #
  # = LocalDb::SqlRunner
  #
  # Runs an SQL script file on the local primary (MySQL) DB with the MariaDB client (see LocalDb::Cli),
  # wrapped in an outer transaction (as 'db:run' always did):
  #
  #   START TRANSACTION;
  #   <file contents>
  #   COMMIT;
  #
  # (ActiveRecord's #execute runs only the first statement of a multi-statement string, hence the client.)
  # The client stops at the first error and the server rolls back the open transaction when the session ends.
  #
  # Never raises for a failed run and never calls +exit+: it returns a Result.
  #
  # == Usage
  #   result = LocalDb::SqlRunner.call(path: '/path/to/0490-x.sql')
  #   result.success?   # => true / false
  #   result.stderr     # => client error output
  #   result.duration   # => seconds (Float)
  #
  class SqlRunner
    Result = Data.define(:success, :stdout, :stderr, :duration, :exit_code) do
      def success? = success
    end

    def self.call(path:, cli: Cli.new)
      new(path:, cli:).call
    end

    def initialize(path:, cli: Cli.new)
      @path = path.to_s
      @cli = cli
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return failure("File not found: #{@path}", started) unless File.file?(@path)

      stdout, stderr, status = Open3.capture3(@cli.env, *@cli.argv, stdin_data: wrapped_sql)
      Result.new(success: status.success?, stdout: stdout.to_s, stderr: stderr.to_s,
                 duration: elapsed(started), exit_code: status.exitstatus)
    rescue SystemCallError, IOError => e
      failure("#{e.class}: #{e.message}", started)
    end

    private

    def wrapped_sql
      "START TRANSACTION;\n#{File.binread(@path)}\nCOMMIT;\n"
    end

    def failure(message, started)
      Result.new(success: false, stdout: '', stderr: message, duration: elapsed(started), exit_code: nil)
    end

    def elapsed(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
  end
end
