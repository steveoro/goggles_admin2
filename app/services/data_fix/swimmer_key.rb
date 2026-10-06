# frozen_string_literal: true

module DataFix
  # SwimmerKey: stateless helpers for parsing and matching swimmer keys in the
  # "G|LAST|First|YOB|Team" format used by phase 3 files and data_import rows.
  module SwimmerKey
    module_function

    # Normalize swimmer key to partial format for matching, preserving the team token.
    # Team is an immutable part of the swimmer key — it must never be stripped during
    # normalization, otherwise same-name swimmers on different teams cross-match.
    # Input:  "M|LIGABUE|Marco|1971|Asd Caserta Nuoto" or "|LIGABUE|Marco|1971|Swimprove ssd"
    # Output: "|LIGABUE|Marco|1971|Asd Caserta Nuoto" (gender stripped, team preserved)
    def normalize_swimmer_key_for_lookup(key)
      return nil if key.blank?

      parts = key.to_s.split('|')
      return nil if parts.size < 3

      offset = swimmer_key_offset(parts)
      last_name = parts[offset]
      first_name = parts[offset + 1]
      year_of_birth = parts[offset + 2]
      team_name = parts[(offset + 3)..]&.join('|')
      return nil if last_name.blank? || first_name.blank?

      normalized = "|#{last_name}|#{first_name}|#{year_of_birth}"
      team_name.present? ? "#{normalized}|#{team_name}" : normalized
    end

    # Determine the offset into split key parts based on the first element:
    # - Single-char gender code (M/F) → offset 1
    # - Empty string (partial key starting with '|') → offset 1
    # - Otherwise (no prefix) → offset 0
    def swimmer_key_offset(parts)
      first = parts[0].to_s
      return 1 if first.match?(/\A[MF]\z/i)
      return 1 if first.blank?

      0
    end

    def swimmer_key_match?(candidate_key, key_a, key_b)
      return false if candidate_key.blank?

      [key_a, key_b].compact.any? { |key| key.present? && candidate_key == key } ||
        begin
          candidate_partial = normalize_swimmer_key_for_lookup(candidate_key)
          target_partials = [key_a, key_b].compact.filter_map { |key| normalize_swimmer_key_for_lookup(key) }
          candidate_partial.present? && target_partials.include?(candidate_partial)
        end
    end

    def swimmer_row_matches?(row_swimmer_key:, row_swimmer_id:, old_swimmer_key:, canonical_swimmer_key:, old_swimmer_id:, new_swimmer_id:)
      id_match = [old_swimmer_id, new_swimmer_id].compact.any? do |target_id|
        target_id.to_i.positive? && row_swimmer_id.to_i == target_id.to_i
      end
      return true if id_match

      swimmer_key_match?(row_swimmer_key, old_swimmer_key, canonical_swimmer_key)
    end

    # Program key of an import/parent key: the "session-event-category-gender"
    # segment before the first '/'. Same partition an `import_key LIKE 'key/%'`
    # query selects, computed without hitting the DB.
    def program_key_of(import_key)
      import_key.to_s.split('/', 2).first
    end

    # TRUE when the program key's trailing gender segment is blank:
    # - "1-100SL-M25-M" => false
    # - "1-100SL-M25-" => true
    def program_key_missing_gender?(program_key)
      return true if program_key.blank?

      program_key.to_s.split('-').last.to_s.strip.blank?
    end
  end
end
