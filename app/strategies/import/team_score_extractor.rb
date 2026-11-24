# frozen_string_literal: true

module Import
  #
  # = TeamScoreExtractor
  #
  # Extracts the overall team ranking (future GogglesDb::MeetingTeamScore rows) from a
  # result source, for the Phase 2 payload ('data.team_scores').
  #
  # Supported sources:
  # - LT4: root 'teamRankings' array (written by Import::Adapters::Layout2To4);
  # - LT2: 'sections' flagged with 'ranking' (PDF-derived files, see PdfResults::L2Converter).
  #
  # Each source row holds raw strings: { 'pos', 'team', 'ind_score', 'overall_score' }.
  #
  # Output: an Array of
  #   { 'team_key' => String, 'rank' => Integer, 'ind_score' => Float, 'overall_score' => Float }
  # deduplicated on the legacy key "#{rank}-#{team}" (first row wins) and sorted by rank.
  # Scores are parsed with Parser::Score.from_l2_result, as in the legacy solver (plus "1.234,50" support).
  #
  class TeamScoreExtractor
    # Returns the extracted team scores for +data_hash+ (see class notes).
    def self.extract(data_hash)
      return [] unless data_hash.is_a?(Hash)

      rows = if data_hash['teamRankings'].is_a?(Array)
               data_hash['teamRankings']
             else
               Array(data_hash['sections']).select { |section| section.is_a?(Hash) && section['ranking'].present? }
                                           .flat_map { |section| Array(section['rows']) }
             end
      normalize_rows(rows)
    end

    # Same as #extract, but when +data_hash+ is an LT4 working copy without 'teamRankings'
    # (materialized before rankings were carried over) it reads the LT2 sibling source
    # ("<base>.json" next to "<base>-lt4.json"), when present.
    def self.from_source(source_path, data_hash)
      return extract(data_hash) if data_hash.is_a?(Hash) && (data_hash.key?('teamRankings') || data_hash.key?('sections'))

      lt2_path = source_path.to_s.sub(/-lt4\.json\z/, '.json')
      return extract(data_hash) if lt2_path == source_path.to_s || !File.exist?(lt2_path)

      extract(JSON.parse(File.read(lt2_path)))
    rescue JSON::ParserError, SystemCallError => e
      Rails.logger.warn("[TeamScoreExtractor] LT2 sibling unreadable for #{source_path}: #{e.message}")
      extract(data_hash)
    end

    def self.normalize_rows(rows)
      seen_keys = {}
      scores = []
      rows.each do |row|
        next unless row.is_a?(Hash) && row['team'].present?

        team_key = row['team']
        rank = row['pos'].to_i
        legacy_key = "#{rank}-#{team_key}"
        next if seen_keys.key?(legacy_key)

        seen_keys[legacy_key] = true
        scores << {
          'team_key' => team_key,
          'rank' => rank,
          'ind_score' => parse_score(row['ind_score']),
          'overall_score' => parse_score(row['overall_score'])
        }
      end
      scores.each_with_index.sort_by { |score, idx| [score['rank'], idx] }.map(&:first)
    end

    # Parser::Score.from_l2_result, except that dots used as thousands separators together with
    # a decimal comma ("1.234,50") are dropped first (Parser::Score alone would yield 1.234).
    def self.parse_score(text)
      value = text.to_s.strip
      value = value.delete('.') if value.match?(/\A\d{1,3}(\.\d{3})+,\d{1,3}\z/)
      Parser::Score.from_l2_result(value)
    end
    private_class_method :normalize_rows, :parse_score
  end
end
