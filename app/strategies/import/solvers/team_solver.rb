# frozen_string_literal: true

module Import
  module Solvers
    # TeamSolver: builds Phase 2 payload (teams and team_affiliations)
    #
    # Inputs:
    # - LT4: prefer root 'teams' dictionary when present (strings or objects)
    # - LT2: fallback (TODO) scan of sections when LT4 dict missing
    #
    # Output (phase2 file):
    # {
    #   "_meta": { ... },
    #   "data": {
    #     "season_id": <int>,
    #     "teams": [ { "key": "Team Name", "name": "Team Name" } ],
    #     "team_affiliations": [ { "team_key": "Team Name", "season_id": 242 } ]
    #   }
    # }
    #
    class TeamSolver
      def initialize(season:, logger: Rails.logger)
        @season = season
        @logger = logger
      end

      # Build and persist phase2 file
      # opts:
      # - :source_path (String, required)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      #
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        data_hash = JSON.parse(File.read(source_path))

        teams = []
        ta = []

        if lt_format == 4 && (data_hash['teams'].is_a?(Array) || data_hash['teams'].is_a?(Hash))
          if data_hash['teams'].is_a?(Array)
            data_hash['teams'].each do |t|
              name = extract_team_name(t)
              next if name.blank?

              teams << build_team_entry(name, name)
              ta << { 'team_key' => name, 'season_id' => @season.id }
            end
          else
            data_hash['teams'].each do |key, value|
              name = extract_team_name(value)
              next if name.blank?

              teams << build_team_entry(key, name)
              ta << { 'team_key' => key, 'season_id' => @season.id }
            end
          end
        elsif data_hash['sections'].is_a?(Array)
          # LT2 fallback: scan sections/rows for team names
          data_hash['sections'].each do |sec|
            rows = sec['rows'] || []
            rows.each do |row|
              team_name = row['team']
              next if team_name.to_s.strip.empty?

              teams << build_team_entry(team_name, team_name)
              ta << { 'team_key' => team_name, 'season_id' => @season.id }
            end
          end
        else
          @logger.info('[TeamSolver] No LT4 teams dict and no LT2 sections found')
        end

        payload = {
          'season_id' => @season.id,
          'teams' => teams.uniq { |h| h['key'] },
          'team_affiliations' => ta.uniq { |h| [h['team_key'], h['season_id']] }
        }

        phase_path = opts[:phase_path] || default_phase_path_for(source_path, 2)
        pfm = PhaseFileManager.new(phase_path)
        meta = {
          'generator' => self.class.name,
          'source_path' => source_path,
          'parent_checksum' => pfm.checksum(source_path)
        }
        pfm.write!(data: payload, meta: meta)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/MethodLength

      private

      def default_phase_path_for(source_path, phase_num)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase#{phase_num}.json")
      end

      def extract_team_name(t)
        return t if t.is_a?(String)
        return t['name'] if t.is_a?(Hash)

        nil
      end

      # Build a team entry with fuzzy matches and auto-assignment
      # key: immutable reference key (original team name from source)
      # name: team name to search for
      def build_team_entry(key, name)
        entry = {
          'key' => key,
          'name' => name,
          'editable_name' => name,
          'name_variations' => nil,
          'team_id' => nil,
          'city_id' => nil
        }

        # Find fuzzy matches
        matches = find_team_matches(name)
        entry['fuzzy_matches'] = matches

        # Auto-assign top match if it's very good (exact match or close enough)
        if matches.present? && auto_assignable?(matches.first, name)
          top_match = matches.first
          entry['team_id'] = top_match['id']
          entry['editable_name'] = top_match['editable_name']
          entry['name'] = top_match['name']
          entry['name_variations'] = top_match['name_variations']
          entry['city_id'] = top_match['city_id']
          @logger&.info("[TeamSolver] Auto-assigned team '#{key}' -> ID #{top_match['id']}")
        end

        entry
      end

      # Find potential team matches using GogglesDb fuzzy finder with Jaro-Winkler distance
      # Returns array of hashes with team data (id, name, editable_name, etc.) sorted by match weight
      def find_team_matches(name)
        return [] if name.blank?

        # Use CmdFindDbEntity with FuzzyTeam strategy (Jaro-Winkler distance)
        cmd = GogglesDb::CmdFindDbEntity.call(
          GogglesDb::Team,
          { name: name.to_s.strip }
        )

        # Extract matches (sorted by weight descending) and convert to our format
        matches = cmd.matches.respond_to?(:map) ? cmd.matches : []
        matches.map do |match_struct|
          team = match_struct.candidate
          {
            'id' => team.id,
            'name' => team.name,
            'editable_name' => team.editable_name,
            'name_variations' => team.name_variations,
            'city_id' => team.city_id,
            'city_name' => team.city&.name,
            'weight' => match_struct.weight.round(3),
            'display_label' => "#{team.editable_name} (ID: #{team.id}, #{team.city&.name || 'no city'}, match: #{(match_struct.weight * 100).round(1)}%)"
          }
        end
      rescue StandardError => e
        @logger&.warn("[TeamSolver] Error finding team matches for '#{name}': #{e.message}")
        []
      end

      # Determine if top match is good enough for auto-assignment
      # Uses fuzzy match weight (Jaro-Winkler distance) as criterion.
      # Auto-assigns if weight >= 0.90 (90% confidence or higher)
      #
      # This threshold balances accuracy and convenience:
      # - Catches exact matches and close variants
      # - Low false positive rate in production
      # - Operator can still override via dropdown if needed
      def auto_assignable?(match, search_name)
        return false unless match.present? && search_name.present?

        weight = match['weight'].to_f
        weight >= 0.90
      end
    end
  end
end
