# frozen_string_literal: true

require 'set'

module Phase3
  # RelayMergeService merges swimmer and badge data from auxiliary Phase 3 files
  # into the primary Phase 3 payload. It favours filling missing attributes on
  # existing swimmers and keeps badge entries unique.
  class RelayMergeService
    SWIMMER_KEY = 'key'
    BADGE_SIGNATURE_FIELDS = %w[swimmer_key team_key season_id badge_id].freeze

    def initialize(main_data)
      @main_data = main_data || {}
      @main_data['swimmers'] = Array(@main_data['swimmers'])
      @main_data['badges'] = Array(@main_data['badges'])

      @swimmers = @main_data['swimmers']
      @badges = @main_data['badges']
      @swimmers_by_key = @swimmers.index_by { |swimmer| swimmer[SWIMMER_KEY] }

      # Deduplicate badges: remove partial-key badges when full-key badges exist
      deduplicate_initial_badges!

      @badge_signatures = build_badge_signatures(@badges)
      @stats = {
        swimmers_updated: 0,
        badges_added: 0,
        partial_matches_ambiguous: [] # Track swimmers with multiple partial matches
      }

      # Build partial key indexes for flexible matching
      build_partial_key_indexes
    end

    def merge_from(aux_data)
      merge_swimmers(Array(aux_data['swimmers']))
      merge_badges(Array(aux_data['badges']))
      self
    end

    # Enrich swimmers from own badges (within same file)
    # Call this before merge_from to fill gaps from internal data
    def self_enrich!
      enrich_swimmers_from_badges(@badges)
      self
    end

    def result
      @main_data['swimmers'] = @swimmers.sort_by { |swimmer| swimmer[SWIMMER_KEY].to_s }
      @main_data['badges'] = @badges.sort_by do |badge|
        [badge['swimmer_key'].to_s, badge['team_key'].to_s, badge['season_id'].to_i]
      end
      @main_data
    end

    def stats
      @stats.dup
    end

    private

    def merge_swimmers(aux_swimmers)
      # First pass: exact key matches
      aux_swimmers.each do |aux_swimmer|
        key = aux_swimmer[SWIMMER_KEY].to_s
        next if key.blank?

        # Only update existing swimmers - do NOT add new ones from auxiliary files
        # The purpose of enrichment is to fill missing attributes, not expand the dictionary
        existing = @swimmers_by_key[key]
        next unless existing

        @stats[:swimmers_updated] += 1 if merge_swimmer_attributes(existing, aux_swimmer)
      end

      # Second pass: partial key matches for swimmers still missing gender or YOB
      enrich_from_partial_matches(aux_swimmers)
    end

    # Enrich swimmers from badges using partial key matching
    # Badges often have more complete keys (with gender) from individual results
    def enrich_swimmers_from_badges(badges)
      # Build badge indexes for partial matching
      badges_by_name_yob = Hash.new { |h, k| h[k] = [] }

      badges.each do |badge|
        key = badge['swimmer_key'].to_s
        next if key.blank?

        name_yob_key = extract_name_yob_key(key)
        badges_by_name_yob[name_yob_key] << badge if name_yob_key
      end

      @swimmers.each do |swimmer|
        key = swimmer[SWIMMER_KEY].to_s
        next if key.blank?

        # Try to fill missing gender from badge keys
        next unless swimmer['gender_type_code'].to_s.strip.empty?

        name_yob_key = extract_name_yob_key(key)
        next unless name_yob_key

        # Find badges matching the partial key that have gender in their key
        matching_badges = badges_by_name_yob[name_yob_key]
        genders_found = matching_badges.filter_map { |b| extract_gender_from_key(b['swimmer_key']) }.uniq

        if genders_found.size == 1
          swimmer['gender_type_code'] = genders_found.first
          update_swimmer_key_with_gender(swimmer)
          @stats[:swimmers_updated] += 1
        elsif genders_found.size > 1
          @stats[:partial_matches_ambiguous] << {
            swimmer_key: key,
            name: swimmer['complete_name'] || "#{swimmer['last_name']} #{swimmer['first_name']}",
            issue: 'multiple_genders_in_badges',
            found_genders: genders_found
          }
        end
      end
    end

    # Extract gender code from key if present
    # ASSUMES: key starts with the pipe separator even if the gender is missing
    def extract_gender_from_key(key)
      return nil if key.blank?

      parts = key.split('|')
      return nil if parts.empty?

      gender = parts[0].to_s.strip.upcase
      gender.match?(/\A[MF]\z/) ? gender : nil
    end

    # Enrich swimmers with missing data using partial key matching
    # - For missing gender: find aux swimmers matching |LAST|FIRST|YOB (ignoring gender prefix)
    # - For missing YOB: find aux swimmers matching G|LAST|FIRST| (ignoring YOB suffix)
    def enrich_from_partial_matches(aux_swimmers)
      # Build aux indexes for partial matching
      aux_by_name_yob = Hash.new { |h, k| h[k] = [] } # |LAST|FIRST|YOB => [swimmers]
      aux_by_gender_name = Hash.new { |h, k| h[k] = [] } # G|LAST|FIRST| => [swimmers]

      aux_swimmers.each do |aux|
        key = aux[SWIMMER_KEY].to_s
        next if key.blank?

        name_yob_key = extract_name_yob_key(key)
        aux_by_name_yob[name_yob_key] << aux if name_yob_key

        gender_name_key = extract_gender_name_key(key)
        aux_by_gender_name[gender_name_key] << aux if gender_name_key
      end

      @swimmers.each do |swimmer|
        key = swimmer[SWIMMER_KEY].to_s
        next if key.blank?

        # Try to fill missing gender from partial matches
        if swimmer['gender_type_code'].to_s.strip.empty?
          name_yob_key = extract_name_yob_key(key)
          if name_yob_key
            candidates = aux_by_name_yob[name_yob_key].select { |c| c['gender_type_code'].present? }
            unique_genders = candidates.map { |c| c['gender_type_code'] }.uniq

            if unique_genders.size == 1
              # Single unique gender found - use it
              swimmer['gender_type_code'] = unique_genders.first
              update_swimmer_key_with_gender(swimmer)
              @stats[:swimmers_updated] += 1
            elsif unique_genders.size > 1
              # Multiple genders found - ambiguous, record for UI warning
              @stats[:partial_matches_ambiguous] << {
                swimmer_key: key,
                name: swimmer['complete_name'] || "#{swimmer['last_name']} #{swimmer['first_name']}",
                issue: 'multiple_genders',
                found_genders: unique_genders
              }
            end
          end
        end

        # Try to fill missing YOB from partial matches (when gender is known)
        next unless missing_year?(swimmer['year_of_birth']) && swimmer['gender_type_code'].present?

        gender_name_key = extract_gender_name_key(key)
        next unless gender_name_key

        candidates = aux_by_gender_name[gender_name_key].select { |c| present_year?(c['year_of_birth']) }
        unique_yobs = candidates.map { |c| c['year_of_birth'].to_i }.uniq

        if unique_yobs.size == 1
          # Single unique YOB found - use it
          swimmer['year_of_birth'] = unique_yobs.first
          update_swimmer_key_with_yob(swimmer)
          @stats[:swimmers_updated] += 1
        elsif unique_yobs.size > 1
          # Multiple YOBs found - ambiguous, record for UI warning
          @stats[:partial_matches_ambiguous] << {
            swimmer_key: key,
            name: swimmer['complete_name'] || "#{swimmer['last_name']} #{swimmer['first_name']}",
            issue: 'multiple_yobs',
            found_yobs: unique_yobs
          }
        end
      end
    end

    def merge_swimmer_attributes(target, source)
      changed = false
      changed |= copy_if_blank(target, source, 'complete_name')
      changed |= copy_if_blank(target, source, 'first_name')
      changed |= copy_if_blank(target, source, 'last_name')
      changed |= copy_if_blank(target, source, 'name_variations')

      changed |= copy_year_if_missing(target, source)
      changed |= copy_gender_if_missing(target, source)
      changed |= copy_swimmer_id_if_missing(target, source)
      changed |= merge_fuzzy_matches(target, source)
      changed
    end

    def copy_if_blank(target, source, field)
      return false unless target[field].blank? && source[field].present?

      target[field] = source[field]
      true
    end

    def copy_year_if_missing(target, source)
      return false unless missing_year?(target['year_of_birth']) && present_year?(source['year_of_birth'])

      target['year_of_birth'] = source['year_of_birth'].to_i
      true
    end

    def copy_gender_if_missing(target, source)
      return false unless target['gender_type_code'].to_s.strip.empty? && source['gender_type_code'].present?

      target['gender_type_code'] = source['gender_type_code']
      true
    end

    def copy_swimmer_id_if_missing(target, source)
      current_id = target['swimmer_id'].to_i
      source_id = source['swimmer_id'].to_i
      return false if current_id.positive? || source_id <= 0

      target['swimmer_id'] = source_id
      true
    end

    def merge_fuzzy_matches(target, source)
      target_matches = Array(target['fuzzy_matches'])
      source_matches = Array(source['fuzzy_matches'])
      return false if source_matches.empty?

      combined = (target_matches + source_matches).uniq { |match| match_key(match) }
      changed = combined.size != target_matches.size
      target['fuzzy_matches'] = combined if changed
      changed
    end

    def match_key(match)
      match.is_a?(Hash) ? match['id'] || match['label'] || match.to_json : match
    end

    def missing_year?(value)
      value.to_i <= 0
    end

    def present_year?(value)
      value.to_i.positive?
    end

    def merge_badges(aux_badges)
      aux_badges.each do |badge|
        signature = badge_signature(badge)
        next if signature.nil? || @badge_signatures.include?(signature)

        # Use normalized identity to prevent duplicates with different key formats
        # (partial key |LAST|FIRST|YOB vs full key F|LAST|FIRST|YOB)
        normalized_id = normalized_badge_identity(badge)
        next if normalized_id.nil?

        # IMPORTANT: Only process badges for swimmers that exist in our main dictionary.
        # The purpose of merge is to ENRICH existing data, not to add new swimmers/badges
        # from other result files.
        swimmer_key = badge['swimmer_key']
        next unless swimmer_exists_in_main?(swimmer_key)

        # Check if we already have a badge for this swimmer+team+season (by normalized identity)
        existing_idx = @badges.find_index do |existing|
          normalized_badge_identity(existing) == normalized_id
        end

        if existing_idx
          existing = @badges[existing_idx]
          new_has_gender = badge['swimmer_key'].to_s.match?(/^[MF]\|/)
          existing_has_gender = existing['swimmer_key'].to_s.match?(/^[MF]\|/)

          if new_has_gender && !existing_has_gender
            # New badge has full key, existing has partial - replace
            @badge_signatures.delete(badge_signature(existing))
            @badges[existing_idx] = deep_dup(badge)
            @badge_signatures << signature
            @stats[:badges_added] += 1
          end
          # Otherwise keep existing (either both have gender, or existing has and new doesn't)
        else
          # No existing badge with this normalized identity - add new
          @badges << deep_dup(badge)
          @badge_signatures << signature
          @stats[:badges_added] += 1
        end
      end
    end

    # Check if a swimmer exists in our main dictionary (by exact or normalized key)
    def swimmer_exists_in_main?(swimmer_key)
      return false if swimmer_key.blank?

      # Direct key match
      return true if @swimmers_by_key.key?(swimmer_key)

      # Try normalized match (ignoring gender prefix)
      name_yob_key = extract_name_yob_key(swimmer_key)
      return false unless name_yob_key

      @main_by_name_yob[name_yob_key].any?
    end

    # Remove partial-key badges when full-key badges exist for the same swimmer+team+season
    def deduplicate_initial_badges!
      # Group badges by normalized identity
      grouped = @badges.group_by { |badge| normalized_badge_identity(badge) }

      # For each group, keep only the best badge (prefer full key)
      @badges.replace(
        grouped.values.filter_map do |group|
          if group.size == 1
            group.first
          else
            # Prefer badge with gender prefix in key, then with swimmer_id, then with category_type_id
            group.max_by do |b|
              score = 0
              score += 4 if b['swimmer_id'].present?
              score += 2 if b['category_type_id'].present?
              score += 1 if b['swimmer_key'].to_s.match?(/^[MF]\|/)
              score
            end
          end
      )
    end

    # Normalized badge identity: |LAST|FIRST|YOB + team_key + season_id (ignoring gender prefix)
    def normalized_badge_identity(badge)
      key = badge['swimmer_key'].to_s
      return nil if key.blank?

      parts = key.split('|').compact_blank
      return nil if parts.size < 3

      # Handle both formats: GENDER|LAST|FIRST|YOB or LAST|FIRST|YOB
      offset = parts[0]&.length == 1 && parts[0]&.match?(/[MF]/) ? 1 : 0
      last = parts[offset]&.upcase
      first = parts[offset + 1]&.upcase
      yob = parts[offset + 2]

      "#{last}|#{first}|#{yob}|#{badge['team_key']}|#{badge['season_id']}"
    end

    def build_badge_signatures(badges)
      badges.each_with_object(Set.new) do |badge, acc|
        signature = badge_signature(badge)
        acc << signature if signature
      end
    end

    def badge_signature(badge)
      parts = BADGE_SIGNATURE_FIELDS.map { |field| badge[field].presence }
      return nil if parts.compact.empty?

      parts.join('|')
    end

    def deep_dup(value)
      value.deep_dup
    end

    # Build partial key indexes for flexible matching within main data
    def build_partial_key_indexes
      @main_by_name_yob = Hash.new { |h, k| h[k] = [] }
      @main_by_gender_name = Hash.new { |h, k| h[k] = [] }

      @swimmers.each do |swimmer|
        key = swimmer[SWIMMER_KEY].to_s
        next if key.blank?

        name_yob_key = extract_name_yob_key(key)
        @main_by_name_yob[name_yob_key] << swimmer if name_yob_key

        gender_name_key = extract_gender_name_key(key)
        @main_by_gender_name[gender_name_key] << swimmer if gender_name_key
      end
    end

    # Extract |LAST|FIRST|YOB key (ignoring gender prefix)
    # Input: "M|ANGELINI|Mario|2001" or "|ANGELINI|Mario|2001"
    # Output: "|ANGELINI|Mario|2001"
    def extract_name_yob_key(key)
      return nil if key.blank?

      parts = key.split('|')
      return nil if parts.size < 4

      # Key format: G|LAST|FIRST|YOB or |LAST|FIRST|YOB
      # Normalize: always start with pipe, then LAST|FIRST|YOB
      return nil unless parts[0].match?(/\A[MF]?\z/i)

      # First part is gender or empty - take remaining parts
      last = parts[1]
      first = parts[2]
      yob = parts[3]

      # No leading pipe/gender - unusual format
      return nil if last.blank? || first.blank? || yob.to_s.strip.empty?

      "|#{last}|#{first}|#{yob}"
    end

    # Extract G|LAST|FIRST| key (ignoring YOB suffix)
    # Input: "M|ANGELINI|Mario|2001"
    # Output: "M|ANGELINI|Mario|"
    def extract_gender_name_key(key)
      return nil if key.blank?

      parts = key.split('|')
      return nil if parts.size < 4

      gender = parts[0].to_s.strip.upcase
      return nil unless gender.match?(/\A[MF]\z/)

      last = parts[1]
      first = parts[2]

      return nil if last.blank? || first.blank?

      "#{gender}|#{last}|#{first}|"
    end

    # Update swimmer key to include gender prefix when gender is newly set
    def update_swimmer_key_with_gender(swimmer)
      key = swimmer[SWIMMER_KEY].to_s
      gender = swimmer['gender_type_code'].to_s.strip.upcase
      return if key.blank? || gender.blank?

      # Only update if key currently has no gender prefix
      return unless key.start_with?('|')

      # Key format: |LAST|FIRST|YOB -> G|LAST|FIRST|YOB
      new_key = "#{gender}#{key}"
      swimmer[SWIMMER_KEY] = new_key

      # Update index
      @swimmers_by_key.delete(key)
      @swimmers_by_key[new_key] = swimmer
    end

    # Update swimmer key to include YOB when YOB is newly set
    def update_swimmer_key_with_yob(swimmer)
      key = swimmer[SWIMMER_KEY].to_s
      yob = swimmer['year_of_birth'].to_i
      return if key.blank? || yob <= 0

      parts = key.split('|')
      return if parts.size < 4

      # Update YOB in key if it was empty/zero
      return unless parts[3].to_s.strip.empty? || parts[3].to_i <= 0

      parts[3] = yob.to_s
      new_key = parts.join('|')
      swimmer[SWIMMER_KEY] = new_key

      # Update index
      @swimmers_by_key.delete(key)
      @swimmers_by_key[new_key] = swimmer
    end
  end
end
