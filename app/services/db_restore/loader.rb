# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Loader
  #
  # Wizard step 6 (inside DbRestore::RestoreJob, lock held, queues paused): drops and recreates the target database
  # with the MySQL client, then streams the dump into it: the compressed file is read by Ruby (progress = compressed
  # bytes read), decompressed by `bunzip2 -c` and piped into `mariadb --database=<target>`; no uncompressed copy is
  # written to disk. Same statements as goggles_db's db:rebuild (DROP DATABASE IF EXISTS, CREATE DATABASE, source).
  #
  # The sandbox line that recent mariadb-dump versions put at the top of a dump is kept when the local client
  # understands it and dropped otherwise (see #filter_sandbox?: the old-client fix of db:dump_remove_sandbox).
  #
  # Progress: Ops::RestoreRun#heartbeat! every +progress_every+ seconds from a separate thread (also while the client
  # is busy and the pipe is full), so a stopped heartbeat means a dead worker (Ops::RestoreRun#stalled?).
  # Credentials: only in the child environment (DbRestore::Target#process_env); nothing is logged but step names.
  #
  class Loader
    # First MariaDB client version of each series understanding the '/*M!999999\- enable the sandbox mode */' line.
    SANDBOX_SINCE = { '10.5' => 25, '10.6' => 18, '10.11' => 8, '11.0' => 6, '11.1' => 5, '11.2' => 4, '11.4' => 2 }.freeze
    CLIENT_VERSION = /(\d+)\.(\d+)\.(\d+)-MariaDB/

    attr_reader :run, :target

    # == Params
    # - run: the Ops::RestoreRun; target: DbRestore::Target; commands: DbRestore::Commands (or a spec fake);
    # - progress_every: heartbeat period in seconds (nil: only the final heartbeat).
    def initialize(run:, target: DbRestore::Target.current, commands: DbRestore::Commands, progress_every: 2)
      @run = run
      @target = target
      @commands = commands
      @progress_every = progress_every
    end

    # Loads +dump_path+ (the run's dump by default) into the target database. Raises on any failure.
    def call(dump_path = run.dump_path)
      raise Refused, I18n.t('db_restore.errors.dump_missing', path: dump_path) unless File.file?(dump_path.to_s)
      raise Refused, I18n.t('db_restore.errors.target_refused') unless target.ok?

      drop_and_create!
      stream!(dump_path.to_s)
      run.heartbeat!(File.size(dump_path.to_s))
    end

    def drop_and_create!
      run.step!(:drop_create)
      db = quoted_database
      @commands.capture!(target.process_env, target.client_argv('mariadb', "--execute=DROP DATABASE IF EXISTS #{db}; CREATE DATABASE #{db};"))
    end

    def stream!(dump_path)
      run.step!(:load)
      @fed = 0
      heartbeat = start_heartbeat
      @commands.load_stream(env: target.process_env, decompress_argv: %w[bunzip2 -c],
                            client_argv: target.client_argv('mariadb', "--database=#{target.database}"),
                            input_path: dump_path, filter_sandbox: filter_sandbox?) { |bytes| @fed = bytes }
    ensure
      heartbeat&.kill
    end

    # True when the local client is too old for the sandbox line (or its version can't be read).
    def filter_sandbox?
      return @filter_sandbox if defined?(@filter_sandbox)

      @filter_sandbox = !self.class.sandbox_supported?(@commands.output(%w[mariadb --version]))
    end

    # True when the client version string (`mariadb --version`) understands the sandbox line.
    def self.sandbox_supported?(version_text)
      match = CLIENT_VERSION.match(version_text.to_s)
      return false unless match

      major, minor, patch = match.captures.map(&:to_i)
      series = "#{major}.#{minor}"
      return patch >= SANDBOX_SINCE[series] if SANDBOX_SINCE.key?(series)

      major > 11 || (major == 11 && minor >= 5)
    end

    private

    def quoted_database
      name = target.database
      raise Refused, I18n.t('db_restore.errors.target_refused') unless name.match?(DbRestore::Target::NAME_FORMAT)

      "`#{name}`"
    end

    def start_heartbeat
      return if @progress_every.blank?

      Thread.new do
        Thread.current.report_on_exception = false
        loop do
          sleep(@progress_every)
          Ops.safely { run.heartbeat!(@fed) }
        end
      end
    end
  end
end
