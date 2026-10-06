# frozen_string_literal: true

module DataFix
  # CommitArchiver: post-commit file + staging-table bookkeeping for Phase 6.
  # Writes the uploadable SQL batch file, moves the source JSON (plus its LT2
  # counterpart and all phase files) into results.done/<season>/, deletes the
  # data_import_* staging rows and appends the post-commit log section.
  module CommitArchiver
    extend self

    # @param source_path [String] canonical LT4 source path (moved to results.done)
    # @param lt2_source_path [String] optional original LT2 source path (moved when present)
    # @param phase1_path [String] used to read season_id
    # @param phase_paths [Array<String>] all phase files to archive
    # @param sql_full_path [String] destination path of the generated .sql batch file
    # @param log_full_path [String] commit log path (post-commit section appended)
    # @param sql_content [String] SQL text for the batch file
    # @return [Hash] { season_id:, done_dir: }
    def finalize(source_path:, lt2_source_path:, phase1_path:, phase_paths:, sql_full_path:, log_full_path:, sql_content:)
      # Generate SQL file in results.new directory
      File.write(sql_full_path, sql_content)

      # Get season_id for organized archiving
      season_id = PhaseFileManager.new(phase1_path).data['season_id'] || 'unknown'

      source_dir = File.dirname(source_path)

      # Move source JSON and ALL phase files to 'crawler/data/results.done/<season_id>/'
      done_dir = source_dir.gsub('results.new', 'results.done')
      FileUtils.mkdir_p(done_dir)

      # Move source JSON as backup
      done_source_path = File.join(done_dir, File.basename(source_path))
      FileUtils.mv(source_path, done_source_path)

      # Move also LT2 source JSON if it exists and was converted to LT4 for the process
      if File.exist?(lt2_source_path)
        done_lt2_source_path = File.join(done_dir, File.basename(lt2_source_path))
        FileUtils.mv(lt2_source_path, done_lt2_source_path)
      end

      # Move phase files (keep them for audit trail)
      moved_files = [source_path]
      phase_paths.each do |path|
        next unless File.exist?(path)

        done_phase_path = File.join(done_dir, File.basename(path))
        FileUtils.mv(path, done_phase_path)
        moved_files << path
      end

      # Clean up data_import_* tables for this source (use source_path as reference - before move!)
      mir_deleted = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).delete_all
      lap_deleted = GogglesDb::DataImportLap.where(phase_file_path: source_path).delete_all
      mrr_deleted = GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).delete_all
      mrs_deleted = GogglesDb::DataImportMeetingRelaySwimmer.where(phase_file_path: source_path).delete_all
      relay_lap_deleted = GogglesDb::DataImportRelayLap.where(phase_file_path: source_path).delete_all
      total_deleted = mir_deleted + lap_deleted + mrr_deleted + mrs_deleted + relay_lap_deleted

      # Append post-commit operations to log file
      File.open(log_full_path, 'a') do |f|
        f.puts
        f.puts '=== POST-COMMIT OPERATIONS ==='
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] moved #{moved_files.size} files to #{done_dir}"
        moved_files.each { |path| f.puts "  - #{File.basename(path)}" }
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] cleaned up #{total_deleted} data_import_* temp records"
        f.puts "  - DataImportMeetingIndividualResult: #{mir_deleted}"
        f.puts "  - DataImportLap: #{lap_deleted}"
        f.puts "  - DataImportMeetingRelayResult: #{mrr_deleted}"
        f.puts "  - DataImportMeetingRelaySwimmer: #{mrs_deleted}"
        f.puts "  - DataImportRelayLap: #{relay_lap_deleted}"
      end

      { season_id: season_id, done_dir: done_dir }
    end
  end
end
