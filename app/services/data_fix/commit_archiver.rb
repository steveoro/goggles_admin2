# frozen_string_literal: true

module DataFix
  # CommitArchiver: post-commit file + staging-table bookkeeping for Phase 6.
  # Moves the source JSON (plus its LT2 counterpart and all phase files) into results.done/<season>/,
  # deletes the data_import_* staging rows and appends the post-commit log section.
  #
  # The SQL batch file is no longer written here: since the SQL Outbox it is registered by Outbox::Writer
  # inside the local commit transaction (see Import::Committers::Main#commit_all, before_commit:).
  #
  # Idempotent ("Retry archiving", DataFix::CommitsController#retry_archive): it moves only the files still
  # in results.new and deletes only the staging rows left.
  module CommitArchiver
    module_function

    # @param source_path [String] canonical LT4 source path (moved to results.done)
    # @param lt2_source_path [String] optional original LT2 source path (moved when present)
    # @param phase1_path [String] used to read season_id (its results.done copy after a partial run)
    # @param phase_paths [Array<String>] all phase files to archive
    # @param log_full_path [String] commit log path (post-commit section appended)
    # @return [Hash] { season_id:, done_dir:, moved: [paths] }
    def finalize(source_path:, lt2_source_path:, phase1_path:, phase_paths:, log_full_path:)
      source_dir = File.dirname(source_path)
      # Move source JSON and ALL phase files to 'crawler/data/results.done/<season_id>/'
      done_dir = source_dir.gsub('results.new', 'results.done')
      season_id = read_season_id(phase1_path, done_dir)
      FileUtils.mkdir_p(done_dir)

      # Source JSON (backup), LT2 source JSON (when converted to LT4 for the process), phase files (audit trail):
      moved_files = [source_path, lt2_source_path, *phase_paths].compact.uniq.select do |path|
        next false unless File.exist?(path)

        FileUtils.mv(path, File.join(done_dir, File.basename(path)))
        true
      end

      # Clean up data_import_* tables for this source (use source_path as reference - before move!)
      deleted = purge_staging_rows(source_path)
      append_log(log_full_path, done_dir, moved_files, deleted)

      { season_id: season_id, done_dir: done_dir, moved: moved_files }
    end

    # Season id from the phase 1 file (still in results.new, or already archived), or 'unknown'.
    def read_season_id(phase1_path, done_dir)
      path = [phase1_path, File.join(done_dir, File.basename(phase1_path.to_s))].find { |candidate| File.exist?(candidate.to_s) }
      (path && PhaseFileManager.new(path).data['season_id']) || 'unknown'
    end

    # Returns { 'DataImportMeetingIndividualResult' => count, ... }
    def purge_staging_rows(source_path)
      [
        GogglesDb::DataImportMeetingIndividualResult, GogglesDb::DataImportLap, GogglesDb::DataImportMeetingRelayResult,
        GogglesDb::DataImportMeetingRelaySwimmer, GogglesDb::DataImportRelayLap
      ].to_h { |model| [model.name.demodulize, model.where(phase_file_path: source_path).delete_all] }
    end

    def append_log(log_full_path, done_dir, moved_files, deleted)
      File.open(log_full_path, 'a') do |f|
        f.puts
        f.puts '=== POST-COMMIT OPERATIONS ==='
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] moved #{moved_files.size} files to #{done_dir}"
        moved_files.each { |path| f.puts "  - #{File.basename(path)}" }
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] cleaned up #{deleted.values.sum} data_import_* temp records"
        deleted.each { |name, count| f.puts "  - #{name}: #{count}" }
      end
    end
  end
end
