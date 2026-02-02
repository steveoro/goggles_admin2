# frozen_string_literal: true

module Import
  module Solvers
    # TeamSolver: builds Phase 2 payload (teams and team_affiliations)
    #
    # Typical inputs:
    # - LT4: prefer root 'swimmers' dictionary when present (strings or objects)
    # - LT2: fallback scan of sections when LT4 dict missing
    #
    # NOTE:
    # LayoutType is indicative, what really counts is the actual hierarchical structure
    # found in the data file (regardless of specified layout type).
    # Output (phase2 file):
    # {
    #   "_meta": { ... },
    #   "data": {
    #     "season_id": <int>,
    #     "teams": [ { "key": "Team Name", "name": "Team Name", "team_id": 123 } ],
    #     "team_affiliations": [ { "team_key": "Team Name", "season_id": 242, "team_id": 123, "team_affiliation_id": 456 } ]
    #   }
    # }
    # NOTE: team_affiliation_id will be nil for new affiliations that don't exist in DB yet
    #
    class TeamSolver # rubocop:disable Metrics/ClassLength
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

        if data_hash['teams'].is_a?(Array) || data_hash['teams'].is_a?(Hash)
          total = data_hash['teams'].size
          if data_hash['teams'].is_a?(Array)
            data_hash['teams'].each_with_index do |t, idx|
              name = extract_team_name(t)
              broadcast_progress('Map teams', idx + 1, total)
              next if name.blank?

              team_entry = build_team_entry(name, name)
              teams << team_entry
              ta << build_team_affiliation_entry(name, team_entry['team_id'])
            end
          else # Hash dictionary: key => teamKey, value => details
            data_hash['teams'].each_with_index do |(key, value), idx|
              name = extract_team_name(value)
              broadcast_progress('Map teams', idx + 1, total)
              next if name.blank?

              team_entry = build_team_entry(key, name)
              teams << team_entry
              ta << build_team_affiliation_entry(key, team_entry['team_id'])
            end
          end

        elsif data_hash['sections'].is_a?(Array)
          # LT2 fallback: scan sections/rows for team names
          total = data_hash['sections'].size
          data_hash['sections'].each_with_index do |sec, idx|
            rows = sec['rows'] || []
            rows.each do |row|
              team_name = row['team']
              next if team_name.to_s.strip.empty?

              team_entry = build_team_entry(team_name, team_name)
              teams << team_entry
              ta << build_team_affiliation_entry(team_name, team_entry['team_id'])
            end
            broadcast_progress('Collect teams from sections', idx + 1, total)
          end
        else
          @logger.info('[TeamSolver] No LT4 teams dict and no LT2 sections found')
        end

        payload = {
          'season_id' => @season.id,
          'teams' => teams.uniq { |h| h['key'] }.sort_by { |h| h['key'] },
          'team_affiliations' => ta.uniq { |h| [h['team_key'], h['season_id']] }.sort_by { |h| h['team_key'] }
        }

        phase_path = opts[:phase_path] || default_phase_path_for(source_path, 2)
        pfm = PhaseFileManager.new(phase_path)
        meta = {
          'generator' => self.class.name,
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'layoutType' => lt_format,
          'phase' => 2,
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

      def extract_team_name(t) # rubocop:disable Naming/MethodParameterName
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
          'city_id' => nil,
          'match_percentage' => 0.0
        }

        # Find fuzzy matches
        matches = find_team_matches(name)
        entry['fuzzy_matches'] = matches

        # Store top match percentage for filtering (0.0 if no matches)
        entry['match_percentage'] = matches.first&.dig('percentage') || 0.0

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
          weight = match_struct.weight.round(3)
          percentage = (weight * 100).round(1)

          # Color coding based on match percentage
          color_class = case percentage
                        when 90..100 then 'success' # Green - excellent match
                        when 70...90 then 'warning' # Yellow - acceptable/good match
                        when 50...70 then 'danger'  # Red - questionable match
                          # else: no badge pill for very poor match
                        end
          {
            'id' => team.id,
            'name' => team.name,
            'editable_name' => team.editable_name,
            'name_variations' => team.name_variations,
            'city_id' => team.city_id,
            'city_name' => team.city&.name,
            'weight' => weight,
            'percentage' => percentage,
            'color_class' => color_class,
            'display_label' => "#{team.editable_name} (ID: #{team.id}, #{team.city&.name || 'no city'}, match: #{percentage}%)"
          }
        end
      rescue StandardError => e
        @logger&.warn("[TeamSolver] Error finding team matches for '#{name}': #{e.message}")
        []
      end

      # Determine if top match is good enough for auto-assignment
      # Uses fuzzy match weight (Jaro-Winkler distance) as criterion.
      # Auto-assigns if weight >= 0.80 (80% confidence or higher - lowered to accept more matches)
      #
      # This threshold balances accuracy and convenience:
      # - Catches exact matches and close variants
      # - Increased auto-matching for operator convenience
      # - Operator can still override via dropdown if needed
      def auto_assignable?(match, search_name)
        return false unless match.present? && search_name.present?

        weight = match['weight'].to_f
        weight >= 0.81
      end

      # Build a team affiliation entry with matching logic
      # Attempts to match existing TeamAffiliation if team_id is available
      # Returns hash with team_key, season_id, team_id, and team_affiliation_id (if matched)
      def build_team_affiliation_entry(team_key, team_id)
        affiliation = {
          'team_key' => team_key,
          'season_id' => @season.id,
          'team_id' => team_id,
          'team_affiliation_id' => nil
        }

        # Guard clause: skip matching if team_id is missing
        return affiliation unless team_id && @season.id

        # Try to match existing team affiliation
        existing = GogglesDb::TeamAffiliation.find_by(
          season_id: @season.id,
          team_id: team_id
        )

        if existing
          affiliation['team_affiliation_id'] = existing.id
          @logger&.info("[TeamSolver] Matched existing TeamAffiliation ID=#{existing.id} for '#{team_key}'")
        else
          @logger&.debug("[TeamSolver] No existing affiliation found for '#{team_key}' (will create new)")
        end

        affiliation
      rescue StandardError => e
        @logger&.error("[TeamSolver] Error matching team affiliation for '#{team_key}': #{e.message}")
        affiliation # Return affiliation without ID on error
      end

      # Broadcast progress updates via ActionCable for real-time UI feedback
      def broadcast_progress(message, current, total)
        ActionCable.server.broadcast(
          'ImportStatusChannel',
          { msg: message, progress: current, total: total }
        )
      rescue StandardError => e
        @logger&.warn("[TeamSolver] Failed to broadcast progress: #{e.message}")
      end
    end
  end
end
