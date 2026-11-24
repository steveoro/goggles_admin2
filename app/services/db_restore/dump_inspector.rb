# frozen_string_literal: true

require 'English'
require 'open3'

module DbRestore
  #
  # = DbRestore::DumpInspector
  #
  # Read-only inspection of a bzipped production dump (wizard step 3, DbRestore::InspectJob): `bzip2 -t` integrity,
  # then one streaming pass over `bzip2 -dc` (no uncompressed file on disk) reading:
  # - the header line written by goggles_db's db:dump ('-- /app/db/dump/production.sql': must name a production
  #   dump) and the client's '-- Host: ...  Database: ...' line;
  # - the table list (CREATE TABLE), which must include DbRestore::CORE_TABLES;
  # - the newest schema_migrations version, which must not be newer than the local engine's newest migration;
  # - the import_queues AUTO_INCREMENT (the next remote import queue id);
  # - the API URL stored in the dump's 'framework_urls' settings (shown on the confirmation, best effort);
  # - the '-- Dump completed on ...' footer (dump time; the file mtime when missing).
  # The Outbox scripts pushed after the dump time are listed as a warning (a replay would need them: none in v1).
  #
  # Nothing else of the rows is read or kept (users, JWTs and personal data are streamed past).
  #
  class DumpInspector # rubocop:disable Metrics/ClassLength
    HEADER_PATH = /\A--\s+(\S+\.sql)\s*\z/
    HOST_LINE = /\A--\s+Host:\s+(\S+)\s+Database:\s+(\S+)/
    CREATE_TABLE = /\ACREATE TABLE `([^`]+)`/
    AUTO_INCREMENT = /AUTO_INCREMENT=(\d+)/
    DUMP_COMPLETED = /\A--\s+Dump completed on\s+(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})/
    SCHEMA_INSERT = 'INSERT INTO `schema_migrations` VALUES'
    SETTINGS_INSERT = 'INSERT INTO `settings` VALUES'
    FRAMEWORK_URLS = /'framework_urls','((?:[^'\\]|\\.)*)'/
    API_ENTRY = /^\s*:?api:\s*['"]?([^\s'"]+)/
    # States of the Outbox scripts that reached the server.
    PUSHED_STATES = %w[sent applied executed_unreported missing_remote failed].freeze
    SCRIPTS_LISTED = 50

    Result = Data.define(:errors, :warnings, :header_line, :source_host, :source_database, :tables, :missing_tables,
                         :schema_version, :local_schema_version, :iq_next_id, :taken_at, :taken_at_source, :bytes,
                         :sha256, :api_url, :scripts_after_dump) do
      def ok? = errors.empty?

      # JSON-able Hash for Ops::RestoreRun#inspection.
      def details
        { 'errors' => errors, 'warnings' => warnings, 'header_line' => header_line, 'source_host' => source_host,
          'source_database' => source_database, 'missing_tables' => missing_tables, 'local_schema_version' => local_schema_version,
          'taken_at_source' => taken_at_source, 'api_url' => api_url, 'scripts_after_dump' => scripts_after_dump,
          'table_count' => tables.size }
      end
    end

    attr_reader :path

    def self.call(path, **options)
      new(path, **options).call
    end

    # == Params
    # - path: the .sql.bz2 file; local_schema_version: newest local migration (default: DbRestore.local_schema_version).
    def initialize(path, local_schema_version: DbRestore.local_schema_version)
      @path = path.to_s
      @local_schema_version = local_schema_version.to_s
    end

    def call
      @errors = []
      @warnings = []
      return result(bytes: nil, sha256: nil) unless readable?

      bytes = File.size(path)
      sha256 = Digest::SHA256.file(path).hexdigest
      return result(bytes:, sha256:) unless integrity_ok?

      scan!
      validate!
      result(bytes:, sha256:)
    end

    private

    def readable?
      return true if File.file?(path) && File.readable?(path)

      @errors << error(:missing)
      false
    end

    def integrity_ok?
      _out, err, status = Open3.capture3('bzip2', '-tq', path)
      return true if status.success?

      @errors << error(:integrity, detail: err.to_s.strip.truncate(300))
      false
    rescue SystemCallError => e
      @errors << error(:integrity, detail: "#{e.class}: #{e.message}")
      false
    end

    # rubocop:disable-next Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    def scan!
      @tables = []
      @versions = []
      current_table = nil
      IO.popen(['bzip2', '-dc', path], 'rb', err: File::NULL) do |io|
        io.each_line.with_index do |line, index|
          if index.zero?
            @header_line = text(line).strip.truncate(200)
          elsif line.start_with?('-- ')
            read_comment(line)
          elsif (match = CREATE_TABLE.match(line))
            current_table = text(match[1])
            @tables << current_table
          elsif line.start_with?(') ENGINE') && current_table == 'import_queues' && (match = AUTO_INCREMENT.match(line))
            @iq_next_id = match[1].to_i
          elsif line.start_with?(SCHEMA_INSERT)
            @versions.concat(line.scan(/'(\d{14})'/).flatten.map { |version| text(version) })
          elsif line.start_with?(SETTINGS_INSERT) && @api_url.nil?
            @api_url = dump_api_url(line)
          end
        end
      end
      @errors << error(:unreadable) unless $CHILD_STATUS&.success?
    rescue SystemCallError, IOError => e
      @errors << error(:unreadable, detail: "#{e.class}: #{e.message}")
    end

    def read_comment(line)
      if (match = HOST_LINE.match(line))
        @source_host = text(match[1])
        @source_database = text(match[2])
      elsif (match = DUMP_COMPLETED.match(line))
        @taken_at = Time.zone.parse(text(match[1]))
      end
    end

    def validate!
      @errors << error(:not_production, detail: @header_line.to_s) unless production_header?
      missing = missing_tables
      @errors << error(:missing_tables, detail: missing.join(', ')) if missing.any?
      validate_schema!
      settle_taken_at!
      scripts = scripts_after_dump
      @warnings << warning(:scripts_after_dump, detail: scripts.first(10).join(', '), count: scripts.size) if scripts.any?
    end

    # The dump's schema must not be newer than the local engine (older: the missing migrations are reported later).
    def validate_schema!
      return @errors << error(:no_schema_version) if schema_version.blank?
      return if @local_schema_version.blank? || schema_version == @local_schema_version

      if schema_version > @local_schema_version
        @errors << error(:schema_newer, detail: "#{schema_version} > #{@local_schema_version}")
      else
        @warnings << warning(:schema_older, detail: "#{schema_version} < #{@local_schema_version}")
      end
    end

    # Dump time: the 'Dump completed' footer, else the file mtime (with a warning).
    def settle_taken_at!
      if @taken_at
        @taken_at_source = 'footer'
      else
        @taken_at = File.mtime(path)
        @taken_at_source = 'mtime'
        @warnings << warning(:no_dump_date)
      end
    end

    def production_header?
      match = HEADER_PATH.match(@header_line.to_s)
      match.present? && File.basename(match[1]).start_with?('production')
    end

    def missing_tables
      DbRestore::CORE_TABLES - Array(@tables)
    end

    def schema_version
      Array(@versions).max
    end

    # Filenames of the Outbox scripts pushed after the dump was taken (newest last).
    def scripts_after_dump
      return [] if @taken_at.nil?

      @scripts_after_dump ||= Ops.safely([]) do
        next [] unless Ops.available?

        Ops::SqlScript.in_state(PUSHED_STATES).where(Ops::SqlScript.arel_table[:pushed_at].gt(@taken_at))
                      .ordered.limit(SCRIPTS_LISTED).pluck(:filename)
      end
    end

    # The 'api' entry of the dump's framework_urls settings (YAML text inside the INSERT), or nil.
    def dump_api_url(line)
      match = FRAMEWORK_URLS.match(line)
      return unless match

      yaml = text(match[1]).gsub('\\n', "\n").gsub("\\'", "'")
      yaml[API_ENTRY, 1]&.truncate(300)
    end

    def text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')
    end

    def error(code, detail: nil, **values)
      { 'code' => code.to_s, 'detail' => detail }.merge(values.stringify_keys).compact
    end
    alias warning error

    def result(bytes:, sha256:)
      Result.new(errors: @errors, warnings: @warnings, header_line: @header_line, source_host: @source_host,
                 source_database: @source_database, tables: Array(@tables), missing_tables: @tables ? missing_tables : [],
                 schema_version:, local_schema_version: @local_schema_version.presence, iq_next_id: @iq_next_id,
                 taken_at: @taken_at, taken_at_source: @taken_at_source, bytes:, sha256:, api_url: @api_url,
                 scripts_after_dump: @tables ? scripts_after_dump : [])
    end
  end
end
