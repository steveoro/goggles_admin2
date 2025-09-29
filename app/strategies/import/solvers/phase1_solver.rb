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

        payload = {
          'season_id' => @season.id,
          'name' => extract_meeting_name(data_hash, lt_format),
          'meetingURL' => extract_meeting_url(data_hash, lt_format),
          'dateYear1' => nil,
          'dateMonth1' => nil,
          'dateDay1' => nil,
          'dateYear2' => nil,
          'dateMonth2' => nil,
          'dateDay2' => nil,
          'venue1' => extract_venue(data_hash, lt_format),
          'address1' => extract_address(data_hash, lt_format),
          'poolLength' => extract_pool_length(data_hash, lt_format),
          'meeting_session' => [] # UI will add sessions/pools/cities
        }

        # Dates
        set_dates!(payload, data_hash, lt_format)

        # Write phase file
        phase_path = opts[:phase_path] || default_phase_path_for(source_path, 1)
        pfm = PhaseFileManager.new(phase_path)
        meta = {
          'generator' => self.class.name,
          'source_path' => source_path,
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

      def extract_meeting_name(h, lt)
        return h['name'] if lt == 2

        h['meetingName'].presence || h['title']
      end

      def extract_meeting_url(h, lt)
        return h['meetingURL'] if lt == 2

        h['meetingURL']
      end

      def extract_venue(h, lt)
        return h['venue1'] if lt == 2

        h['place']
      end

      def extract_address(h, lt)
        return h['address1'] if lt == 2

        h['place']
      end

      def extract_pool_length(h, _lt)
        h['poolLength']
      end

      def set_dates!(out, h, lt)
        if lt == 2
          # Already split in LT2-style
          nil if out['dateYear1'].present?

        elsif lt == 4
          if h['dates'].is_a?(String)
            parts = h['dates'].split(',')
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
    end
  end
end
