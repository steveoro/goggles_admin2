# frozen_string_literal: true

module Import
  # Shared swimmer name splitting helper used by import solvers.
  #
  # Assumes source full names are in "LAST FIRST" order and applies
  # Italian surname particle heuristics for common 3-token cases.
  module SwimmerNameSplitter
    ITALIAN_SURNAME_PARTICLES = %w[DA DAL DALLA DALLE DE DEI DEL DELLA DELLE DEGLI DI DO LA LE LI LO].freeze

    class << self
      def split_complete_name(swimmer_name)
        clean_name = normalize(swimmer_name)
        return [nil, nil, nil] if clean_name.blank?

        tokens = clean_name.split
        return [tokens.first, nil, tokens.first] if tokens.size == 1

        last_name, first_name = split_tokens(tokens)
        [last_name, first_name, [last_name, first_name].compact.join(' ').presence]
      end

      def resolve_parts(last_name:, first_name:, complete_name: nil)
        normalized_last = normalize(last_name)
        normalized_first = normalize(first_name)
        return [normalized_last, normalized_first, "#{normalized_last} #{normalized_first}".strip] if explicit_parts_reliable?(normalized_last, normalized_first)

        candidate_name = normalize(complete_name).presence || [normalized_last, normalized_first].compact.join(' ').presence
        split_complete_name(candidate_name)
      end

      def italian_surname_particle?(token)
        ITALIAN_SURNAME_PARTICLES.include?(token.to_s.upcase)
      end

      private

      def split_tokens(tokens)
        if tokens.size == 2
          [tokens.first, tokens.last]
        elsif tokens.size == 3
          split_three_tokens(tokens)
        else
          [tokens[0..1].join(' '), tokens[2..].join(' ')]
        end
      end

      def split_three_tokens(tokens)
        if italian_surname_particle?(tokens.first)
          [tokens[0..1].join(' '), tokens.last]
        else
          [tokens.first, tokens[1..2].join(' ')]
        end
      end

      def explicit_parts_reliable?(last_name, first_name)
        return false if last_name.blank? || first_name.blank?
        return false if italian_surname_particle?(last_name) && first_name.include?(' ')

        true
      end

      def normalize(name)
        value = name.to_s.strip
        return nil if value.blank?

        value.tr('`', "'").gsub(/[’]/, "'").squeeze(' ')
      end
    end
  end
end
