# frozen_string_literal: true

module DataFix
  # StagingRows: loads every data_import_* staging row for a source file once
  # and buckets them by program key. Detection, filters, pagination counts and
  # card rendering all reuse these buckets instead of issuing per-program LIKE
  # queries.
  module StagingRows
    extend self

    # @param source_path [String] canonical source file path
    # @return [Hash] raw row arrays plus *_by_program buckets
    def load_staging_rows(source_path)
      mirs = GogglesDb::DataImportMeetingIndividualResult
             .where(phase_file_path: source_path).order(:import_key).to_a
      mrrs = GogglesDb::DataImportMeetingRelayResult
             .where(phase_file_path: source_path).order(:import_key).to_a
      laps = GogglesDb::DataImportLap
             .where(phase_file_path: source_path).order(:length_in_meters).to_a
      relay_swimmers = GogglesDb::DataImportMeetingRelaySwimmer
                       .where(phase_file_path: source_path).order(:relay_order).to_a
      relay_laps = GogglesDb::DataImportRelayLap
                   .includes(:data_import_meeting_relay_swimmer)
                   .where(phase_file_path: source_path).order(:length_in_meters).to_a

      {
        mirs: mirs,
        mrrs: mrrs,
        laps: laps,
        relay_swimmers: relay_swimmers,
        relay_laps: relay_laps,
        mirs_by_program: mirs.group_by { |row| SwimmerKey.program_key_of(row.import_key) },
        mrrs_by_program: mrrs.group_by { |row| SwimmerKey.program_key_of(row.import_key) },
        laps_by_program: laps.group_by { |row| SwimmerKey.program_key_of(row.parent_import_key) },
        relay_swimmers_by_program: relay_swimmers.group_by { |row| SwimmerKey.program_key_of(row.import_key) },
        relay_laps_by_program: relay_laps.group_by { |row| SwimmerKey.program_key_of(row.parent_import_key) }
      }
    end
  end
end
