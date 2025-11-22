# frozen_string_literal: true

module Import
  module Solvers
    # Phase1Solver: builds the minimal phase file for Step 1 (Sessions)
    # Entities handled:
    # - Season (resolved from path or param)
    # - Meeting (basic header, name/URL/dates)
    # - MeetingSession (>=1; based on dates)
    # - SwimmingPool (one per session, linked to City)
    # - City (optional, linked to SwimmingPool)
    #
    # Input sources:
    # - LT2 canonical header (preferred when present)
    # - LT4 header (meeting name, dates) + operator-fed fields in UI
    #
    # Output:
    # - <original>.phase1.json via PhaseFileManager, with only phase 1 payload
    #   and metadata (schema_version, created_at, source_path, checksums).
    #
    class Phase1Solver
      def initialize(season:, logger: Rails.logger)
        @season = season
        @logger = logger
      end

      # Build and persist phase1 file
      #
      # opts:
      # - :source_path (String, required)
      # - :data_hash (Hash, optional; pre-loaded JSON)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      #
      # Returns: written payload (Hash)
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        data_hash = opts[:data_hash] || JSON.parse(File.read(source_path))
        meeting_name = extract_meeting_name(data_hash, lt_format)

        payload = {
          'season_id' => @season.id,
          'name' => meeting_name, # Form input
          'description' => meeting_name, # meeting.description field
          'meetingURL' => extract_meeting_url(data_hash, lt_format),
          'dateYear1' => nil,
          'dateMonth1' => nil,
          'dateDay1' => nil,
          'dateYear2' => nil,
          'dateMonth2' => nil,
          'dateDay2' => nil,

          # Needed for meeting creation:
          'header_date' => nil, # TODO: meeting.header_date field, ISO date from dateYear1, dateMonth1, dateDay1
          'code' => nil, # TODO: generate
          'header_year' => nil, # TODO: dateYear1

          # Pool fields and sessions:
          'venue1' => extract_venue(data_hash, lt_format),
          'address1' => extract_address(data_hash, lt_format),
          'poolLength' => extract_pool_length(data_hash, lt_format),
          'meeting_session' => [] # UI will add sessions/pools/cities
        }

        # Dates
        set_dates!(payload, data_hash, lt_format)

        # Find potential meeting matches
        payload['meeting_fuzzy_matches'] = find_meeting_matches(payload)

        # Write phase file
        phase_path = opts[:phase_path] || default_phase_path_for(source_path, 1)
        pfm = PhaseFileManager.new(phase_path)
        meta = {
          'generator' => self.class.name,
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'layoutType' => lt_format,
          'phase' => 1,
          'parent_checksum' => pfm.checksum(source_path)
        }
        pfm.write!(data: payload, meta: meta)
      end

      private

      def default_phase_path_for(source_path, phase_num)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase#{phase_num}.json")
      end

      def extract_meeting_name(hsh, layout_type)
        return hsh['name'] if layout_type == 2

        hsh['meetingName'].presence || hsh['title']
      end

      def extract_meeting_url(hsh, layout_type)
        return hsh['meetingURL'] if layout_type == 2

        hsh['meetingURL']
      end

      def extract_venue(hsh, layout_type)
        return hsh['venue1'] if layout_type == 2

        hsh['place']
      end

      def extract_address(hsh, layout_type)
        return hsh['address1'] if layout_type == 2

        hsh['place']
      end

      def extract_pool_length(hsh, _lt)
        hsh['poolLength']
      end

      def set_dates!(out, hsh, layout_type) # rubocop:disable Metrics/AbcSize
        if layout_type == 2
          # Preserve LT2 date fields as-is
          out['dateYear1'] = hsh['dateYear1']
          out['dateMonth1'] = hsh['dateMonth1']
          out['dateDay1'] = hsh['dateDay1']
          out['dateYear2'] = hsh['dateYear2']
          out['dateMonth2'] = hsh['dateMonth2']
          out['dateDay2'] = hsh['dateDay2']
        elsif layout_type == 4
          if hsh['dates'].is_a?(String)
            parts = hsh['dates'].split(',')
            if parts[0]
              y, m, d = parts[0].split('-')
              assign_date_parts(out, '1', y, m, d)
            end
            if parts[1]
              y2, m2, d2 = parts[1].split('-')
              assign_date_parts(out, '2', y2, m2, d2)
            end
          end
        end
      end

      def assign_date_parts(out, idx, y, m, d)
        return unless y && m && d

        out["dateYear#{idx}"]  = y
        out["dateMonth#{idx}"] = month_name(m.to_i)
        out["dateDay#{idx}"]   = d
      end

      def month_name(i)
        %w[Gennaio Febbraio Marzo Aprile Maggio Giugno Luglio Agosto Settembre Ottobre Novembre Dicembre][i - 1]
      rescue StandardError
        nil
      end

      # Find potential meeting matches by searching for meetings with similar description in the same season
      # Returns array of hashes with id and description
      def find_meeting_matches(payload)
        return [] unless payload['name'].present? && payload['season_id'].present?

        # Search for meetings with similar names in the same season
        search_term = payload['name'].to_s.strip
        GogglesDb::Meeting.where(season_id: payload['season_id'])
                          .where('description LIKE ?', "%#{search_term.split.first(3).join('%')}%")
                          .limit(10)
                          .map { |m| { 'id' => m.id, 'description' => m.description } }
      rescue StandardError => e
        @logger&.warn("Phase1Solver: error finding meeting matches: #{e.message}")
        []
      end
    end
  end
end
