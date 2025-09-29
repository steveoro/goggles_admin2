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

              teams << { 'key' => name, 'name' => name }
              ta << { 'team_key' => name, 'season_id' => @season.id }
            end
          else
            data_hash['teams'].each do |key, value|
              name = extract_team_name(value)
              next if name.blank?

              teams << { 'key' => key, 'name' => name }
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

              teams << { 'key' => team_name, 'name' => team_name }
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
    end
  end
end
