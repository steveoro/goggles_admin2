# frozen_string_literal: true

module GogglesCup
  # Deserializes the JSON structure stored in goggle_cups.ranking_data back
  # into the array-of-hashes structure expected by the _ranking.html.haml
  # partial, wrapping each score row hash in a ScoreRow so that the
  # partial's method calls (e.g. row.event_type_code) work unchanged.
  class RankingDataDeserializer
    # Lightweight wrapper that delegates method calls to hash keys,
    # allowing the ranking partial to use dot-access syntax.
    class ScoreRow
      def initialize(hash)
        @hash = hash
      end

      def method_missing(name, *args)
        return @hash[name.to_s] if @hash.key?(name.to_s)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @hash.key?(name.to_s) || super
      end
    end

    def initialize(cup)
      @cup = cup
    end

    def call
      data = parsed_data
      return [] if data.blank? || data['data'].blank?

      scores = data['data']['scores'] || {}
      swimmer_names = fetch_swimmer_names(scores.keys)

      entries = scores.map do |swimmer_id_str, rows|
        build_entry(swimmer_id_str, rows, swimmer_names)
      end
      sort_by_score(entries)
    end

    private

    def build_entry(swimmer_id_str, rows, swimmer_names)
      swimmer_id = swimmer_id_str.to_i
      swimmer_info = swimmer_names[swimmer_id] || ['', nil]
      top_rows = build_top_rows(rows)
      {
        swimmer_id: swimmer_id,
        swimmer_name: swimmer_info[0],
        swimmer_year_of_birth: swimmer_info[1],
        overall_score: top_rows.sum { |tr| tr[:row_score].to_f },
        top_rows: top_rows
      }
    end

    def build_top_rows(rows)
      rows.map do |row_hash|
        {
          row: ScoreRow.new(row_hash),
          row_score: row_hash['row_score']
        }
      end
    end

    def sort_by_score(entries)
      entries.sort_by { |entry| -entry[:overall_score] }
    end

    def parsed_data
      raw = @cup.ranking_data
      return {} if raw.blank?

      raw.is_a?(String) ? JSON.parse(raw) : raw
    end

    def fetch_swimmer_names(ids)
      return {} if ids.blank?

      GogglesDb::Swimmer.where(id: ids.map(&:to_i))
                        .pluck(:id, :complete_name, :year_of_birth)
                        .to_h do |row|
        [row[0], [row[1], row[2]]]
      end
    end
  end
end
