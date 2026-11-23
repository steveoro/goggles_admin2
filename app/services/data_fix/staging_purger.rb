# frozen_string_literal: true

module DataFix
  # StagingPurger: deletes the Data-Fix import staging rows (the five +data_import_*+ tables),
  # either for a single source (+phase_file_path+, same scope as CommitArchiver) or for all of them.
  # Records the +datafix.purged+ ops event (never raises because of it).
  module StagingPurger
    module_function

    # Staging tables, in deletion order (children first).
    TABLES = {
      laps: GogglesDb::DataImportLap,
      relay_laps: GogglesDb::DataImportRelayLap,
      relay_swimmers: GogglesDb::DataImportMeetingRelaySwimmer,
      relay_results: GogglesDb::DataImportMeetingRelayResult,
      individual_results: GogglesDb::DataImportMeetingIndividualResult
    }.freeze

    # True when at least one staging row is bound to the given +source_path+.
    def known_source?(source_path)
      source_path.present? && TABLES.values.any? { |table| table.exists?(phase_file_path: source_path) }
    end

    # Deletes the staging rows of a single source.
    # @return [Hash{Symbol=>Integer}] deleted rows count per table key
    def purge!(source_path)
      deleted = delete_rows(source_path.to_s)
      record_event(source_path.to_s, deleted)
      deleted
    end

    # Deletes every staging row, whatever the source.
    # @return [Hash{Symbol=>Integer}] deleted rows count per table key
    def purge_all!
      deleted = delete_rows(nil)
      record_event(nil, deleted)
      deleted
    end

    # (private-ish helpers)
    def delete_rows(source_path)
      deleted = {}
      ActiveRecord::Base.transaction do
        TABLES.each do |key, table|
          scope = source_path ? table.where(phase_file_path: source_path) : table.all
          deleted[key] = scope.delete_all
        end
      end
      deleted
    end

    # Appends the 'datafix.purged' event to the ops log (never raises).
    def record_event(source_path, deleted)
      Ops.safely do
        Ops.record_event!(
          kind: 'datafix.purged', level: 'info', actor: 'operator',
          season_id: source_path && Integer(File.basename(File.dirname(source_path)), exception: false),
          subject_type: source_path ? 'source' : nil,
          subject_key: source_path,
          data: { 'scope' => source_path || 'all', 'deleted' => deleted.transform_keys(&:to_s) }
        )
      end
    end
  end
end
