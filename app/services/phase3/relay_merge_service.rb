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
      @badge_signatures = build_badge_signatures(@badges)
      @stats = {
        swimmers_added: 0,
        swimmers_updated: 0,
        badges_added: 0
      }
    end

    def merge_from(aux_data)
      merge_swimmers(Array(aux_data['swimmers']))
      merge_badges(Array(aux_data['badges']))
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
      aux_swimmers.each do |aux_swimmer|
        key = aux_swimmer[SWIMMER_KEY].to_s
        next if key.blank?

        if (existing = @swimmers_by_key[key])
          @stats[:swimmers_updated] += 1 if merge_swimmer_attributes(existing, aux_swimmer)
        else
          copied = deep_dup(aux_swimmer)
          copied['fuzzy_matches'] = Array(copied['fuzzy_matches'])
          @swimmers << copied
          @swimmers_by_key[key] = copied
          @stats[:swimmers_added] += 1
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

        @badges << deep_dup(badge)
        @badge_signatures << signature
        @stats[:badges_added] += 1
      end
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
  end
end
