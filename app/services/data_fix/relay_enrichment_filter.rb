# frozen_string_literal: true

module DataFix
  # RelayEnrichmentFilter: trims the relay enrichment summary for display.
  module RelayEnrichmentFilter
    extend self

    # Filter relay enrichment summary based on swimmer ID and issues.
    # - Always removes legs already matched to a swimmer_id > 0
    # - When show_new is false, hides legs whose only issue is missing_swimmer_id
    #
    # @param summary [Array<Hash>] detector summary rows
    # @param show_new [Boolean] include legs whose only issue is missing_swimmer_id
    # @param phase3_data [Hash, nil] Phase 3 payload data (used for swimmer_id lookup)
    def filter_relay_enrichment_summary(summary, show_new, phase3_data)
      # Build swimmer_id lookup from Phase 3 data for double-checking (case-insensitive)
      swimmers_with_id = Set.new
      if phase3_data
        Array(phase3_data['swimmers']).each do |s|
          key = s['key']
          sid = s['swimmer_id'].to_i
          if key.present? && sid.positive?
            swimmers_with_id.add(key.downcase) # Normalize to lowercase
          end
        end
      end

      Array(summary).filter_map do |relay|
        swimmers = Array(relay['swimmers'])

        filtered_swimmers = swimmers.reject do |leg|
          issues = leg['issues'] || {}
          phase3_swimmer = leg['phase3_swimmer'] || {}
          swimmer_id = phase3_swimmer['swimmer_id'].to_i
          phase3_key = leg['phase3_key']

          # Matched swimmers are never part of enrichment list
          # Check both the swimmer_id from phase3_swimmer AND the key lookup (case-insensitive)
          key_matched = phase3_key.present? && swimmers_with_id.include?(phase3_key.downcase)
          matched = swimmer_id.positive? || key_matched

          # New swimmers with only missing_swimmer_id (no other blocking issue)
          only_missing_id = issues['missing_swimmer_id'] && !issues['missing_year_of_birth'] && !issues['missing_gender']
          new_non_blocking = !matched && only_missing_id && !show_new

          matched || new_non_blocking
        end

        next if filtered_swimmers.empty?

        # Recompute missing_counts for the filtered swimmers
        missing_counts = filtered_swimmers.each_with_object(Hash.new(0)) do |leg, acc|
          (leg['issues'] || {}).each do |issue_key, flag|
            acc[issue_key] += 1 if flag
          end
        end

        relay.merge('swimmers' => filtered_swimmers, 'missing_counts' => missing_counts)
      end
    end
  end
end
