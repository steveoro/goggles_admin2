# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Snapshot
  #
  # Wizard step 4 (DbRestore::SnapshotJob, optional, on by default): the safety snapshot of the current local DB,
  # taken before anything is dropped, so that a failed restore can be rolled back (UI "Load safety snapshot", or
  # `db:rebuild from=<name> to=development` in goggles_main).
  #
  # - Needs free space >= 3 x the chosen dump's size in the snapshot folder (DbRestore::DumpCatalog#snapshot_dir).
  # - `mariadb-dump --add-drop-table --routines --events --triggers --single-transaction <db>`, compressed on the fly
  #   to '<folder>/development-<NNNN>-pre-restore.sql.bz2' with the same transaction header / footer as goggles_db's
  #   db:dump and its DEFINER clauses stripped (written as '.partial' first, renamed when complete and non-empty).
  # - Then Ops::Database.backup!(label: 'pre_restore') of the ops DB file.
  #
  class Snapshot
    SPACE_FACTOR = 3
    # Same expression as goggles_db's db:dump (SQL_DEFINER_REGEX).
    DEFINER = %r{DEFINER\s*=\s*(?:`[^`]+`@`[^`]+`|'[^']+'@'[^']+'|[^\s*/;]+)\s*}i

    attr_reader :run, :target, :catalog

    def initialize(run:, target: DbRestore::Target.current, catalog: DbRestore::DumpCatalog.new, commands: DbRestore::Commands)
      @run = run
      @target = target
      @catalog = catalog
      @commands = commands
    end

    # Takes the snapshot; returns its path. Raises DbRestore::Refused / DbRestore::CommandFailed.
    def call
      path = catalog.next_snapshot_path
      raise Refused, I18n.t('db_restore.errors.no_snapshot_dir') if path.nil?

      check_space!(File.dirname(path))
      partial = "#{path}.partial"
      @commands.dump_to(env: target.process_env, dump_argv:, out_path: partial, header: header(path), footer:,
                        line_filter: ->(line) { line.gsub(DEFINER, '') })
      raise CommandFailed, I18n.t('db_restore.errors.snapshot_empty') unless File.size?(partial)

      File.rename(partial, path)
      backup = Ops::Database.backup!(label: 'pre_restore')
      run.update!(snapshot_path: path, ops_backup_path: backup&.to_s)
      path
    ensure
      FileUtils.rm_f(partial) if partial && File.exist?(partial)
    end

    def dump_argv
      target.client_argv('mariadb-dump', '--add-drop-table', '--routines', '--events', '--triggers', '--single-transaction',
                         target.database)
    end

    # db:dump's header (create_sql_transaction_header), naming the uncompressed file.
    def header(path)
      "-- #{path.delete_suffix('.bz2')}\r\n" \
        "SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";\n" \
        "SET AUTOCOMMIT = 0;\n" \
        "START TRANSACTION;\n" \
        "\r\n--\r\n"
    end

    # db:dump's footer (append_sql_transaction_footer).
    def footer
      "\r\n--\r\nCOMMIT;\n"
    end

    private

    def check_space!(dir)
      needed = run.dump_bytes.to_i * SPACE_FACTOR
      free = @commands.free_bytes(dir)
      raise Refused, I18n.t('db_restore.errors.space_unknown', dir:) if free.nil?
      return if free >= needed

      raise Refused, I18n.t('db_restore.errors.space', dir:, free: ActiveSupport::NumberHelper.number_to_human_size(free),
                                                       needed: ActiveSupport::NumberHelper.number_to_human_size(needed))
    end
  end
end
