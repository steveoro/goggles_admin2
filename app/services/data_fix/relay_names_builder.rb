# frozen_string_literal: true

module DataFix
  # RelayNamesBuilder: rebuilds the relay leg swimmer name lookup from the
  # source JSON when relay-swimmer rows are missing from staging.
  class RelayNamesBuilder
    # @param source_resolver [SourceResolver] resolver instance holding the
    #   parsed source JSON memo for this request
    def initialize(source_resolver = SourceResolver.new)
      @source_resolver = source_resolver
    end

    # Build relay swimmer name lookup from source data
    # Returns: {mrr_import_key => {relay_order => {name: ..., key: ...}}}
    def build_from_source(source_path, relay_import_keys)
      return {} unless File.exist?(source_path)
      return {} if relay_import_keys.blank?

      source_data = @source_resolver.parsed_source_json(source_path)
      result = {}

      # Parse sections for relay results
      sections = source_data['sections'] || []
      sections.each do |section|
        rows = section['rows'] || []
        rows.each do |row|
          next unless row['relay']

          # Build import key for this row (matches Phase5Populator logic)
          session_order = section['session_order'] || 1
          distance = section['event_length'] || section['distance']
          stroke = section['event_stroke'] || section['stroke']
          next if distance.blank? || stroke.blank?

          event_code = "#{distance}#{stroke}"
          category = section['fin_sigla_categoria']
          gender = section['fin_sesso'] || 'X'
          team_key = row['team']
          timing_string = row['timing'] || '0'

          program_key = "#{session_order}-#{event_code}-#{category}-#{gender}"
          # Use same format as GogglesDb::DataImportMeetingRelayResult.build_import_key
          mrr_import_key = "#{program_key}/#{team_key}-#{timing_string}"

          # Only process if this import_key is in our relay results
          next unless relay_import_keys.include?(mrr_import_key)

          # Extract swimmer names from laps
          laps = row['laps'] || []
          result[mrr_import_key] = {}

          laps.each_with_index do |lap, idx|
            relay_order = idx + 1
            swimmer_key_raw = lap['swimmer'] || ''
            swimmer_parts = swimmer_key_raw.split('|')

            # Parse composite key to extract name and build Phase 3 key
            if swimmer_parts.size >= 5
              last_name = swimmer_parts[1]
              first_name = swimmer_parts[2]
              year = swimmer_parts[3]
            elsif swimmer_parts.size >= 4
              last_name = swimmer_parts[0]
              first_name = swimmer_parts[1]
              year = swimmer_parts[2]
            else
              next
            end

            swimmer_key = "#{last_name}|#{first_name}|#{year}"
            swimmer_name = "#{first_name} #{last_name}".strip

            result[mrr_import_key][relay_order] = {
              'name' => swimmer_name,
              'key' => swimmer_key
            }
          end
        end
      end

      result
    rescue StandardError => e
      Rails.logger.error("[DataFix::RelayNamesBuilder] Error building relay swimmer names: #{e.message}")
      {}
    end
  end
end
