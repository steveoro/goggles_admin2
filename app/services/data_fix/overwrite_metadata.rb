# frozen_string_literal: true

module DataFix
  # OverwriteMetadata: accessor for the Phase 5 'individual_result_overwrite'
  # metadata block used by the three overwrite actions and by verify/confirm
  # result-duplicate lookups (merge targets).
  module OverwriteMetadata
    extend self

    def overwrite_phase5_path_for(file_path)
      raise ArgumentError, 'Missing file path' if file_path.blank?

      resolver = SourceResolver.new
      source_path = resolver.resolve_working_source_path(file_path)
      phase5_path = resolver.default_phase_path_for(source_path, 5)
      raise ArgumentError, 'Phase 5 file not found' unless File.exist?(phase5_path)

      phase5_path
    end

    def read_overwrite_metadata!(phase5_path)
      payload = JSON.parse(File.read(phase5_path))
      meta = payload['_meta']
      overwrite = meta.is_a?(Hash) ? meta['individual_result_overwrite'] : nil
      raise ArgumentError, 'Individual-result overwrite metadata not found' unless overwrite.is_a?(Hash)

      [payload, overwrite]
    end

    # Returns the overwrite candidate (with 'id' as source MIR id) that has this
    # data_import_row as its merge target, or nil when no active merge points here.
    def merge_target_for(data_import_row)
      return nil unless data_import_row.is_a?(GogglesDb::DataImportMeetingIndividualResult) &&
                        data_import_row.phase_file_path.present? &&
                        data_import_row.import_key.present?

      phase5_path = overwrite_phase5_path_for(data_import_row.phase_file_path)
      return nil unless File.exist?(phase5_path)

      _payload, overwrite = read_overwrite_metadata!(phase5_path)
      return nil unless overwrite['enabled'] == true

      candidates = Array(overwrite.dig('snapshot', 'candidates'))
      merge_candidate = candidates.find do |c|
        c['merge'] == true && c['merge_target_import_key'] == data_import_row.import_key
      end
      merge_candidate&.slice('id')
    rescue StandardError => e
      Rails.logger.warn("[DataFix::OverwriteMetadata] merge_target_for failed: #{e.message}")
      nil
    end

    def write_phase5_payload!(phase5_path, payload)
      temporary_path = "#{phase5_path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
      File.write(temporary_path, JSON.pretty_generate(payload))
      File.rename(temporary_path, phase5_path)
    ensure
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def overwrite_counts(snapshot)
      candidates = Array(snapshot['candidates'])
      selected = candidates.select { |candidate| candidate['selected'] == true }
      {
        selected_count: selected.size,
        merge_count: selected.count { |candidate| candidate['merge'] == true },
        total_count: candidates.size
      }
    end
  end
end
