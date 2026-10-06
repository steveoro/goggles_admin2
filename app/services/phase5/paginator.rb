# frozen_string_literal: true

module Phase5
  # Paginator: splits Phase 5 programs across pages when total rows
  # (results + laps) exceed the limit, and sorts them by event order
  # taken from the Phase 4 file.
  class Paginator
    # Phase 5 pagination constant: max rows (results + laps) per page
    MAX_ROWS_PER_PAGE = 2500

    # Paginate Phase 5 programs to prevent UI slowdown
    # Splits programs across pages when total rows (results + laps) exceed limit
    #
    # @param programs [Array<Hash>] all programs from phase5 JSON
    # @param page [Integer] current page number (1-indexed)
    # @param staging [Hash] buckets from StagingRows.load_staging_rows
    # @return [Array<Array, Integer>] [programs_for_page, total_pages]
    def self.paginate(programs, page, staging)
      return [programs, 1] if programs.empty?

      # Calculate row count for each program (results + laps)
      programs_with_counts = programs.map do |prog|
        program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"

        if prog['relay']
          # Count relay results and relay laps
          result_count = (staging[:mrrs_by_program][program_key] || []).size
          lap_count = (staging[:relay_laps_by_program][program_key] || []).size
        else
          # Count individual results and laps
          result_count = (staging[:mirs_by_program][program_key] || []).size
          lap_count = (staging[:laps_by_program][program_key] || []).size
        end

        { program: prog, row_count: result_count + lap_count }
      end

      # Split programs into pages based on MAX_ROWS_PER_PAGE
      pages = []
      current_page_programs = []
      current_page_rows = 0

      programs_with_counts.each do |prog_data|
        # If adding this program exceeds limit, start new page
        if current_page_rows.positive? && (current_page_rows + prog_data[:row_count]) > MAX_ROWS_PER_PAGE
          pages << current_page_programs
          current_page_programs = []
          current_page_rows = 0
        end

        current_page_programs << prog_data[:program]
        current_page_rows += prog_data[:row_count]
      end

      # Add last page if not empty
      pages << current_page_programs unless current_page_programs.empty?

      # Return programs for requested page
      total_pages = [pages.size, 1].max
      page_index = (page - 1).clamp(0, total_pages - 1)
      [pages[page_index] || [], total_pages]
    end

    # Sort programs by event order from phase4
    # Individual events come first (sorted by session_order, event_order), then relays
    #
    # @param programs [Array<Hash>] programs from phase5 JSON
    # @param phase4_path [String] path to phase4 JSON file
    # @return [Array<Hash>] sorted programs
    def self.sort_by_event_order(programs, phase4_path)
      return programs unless File.exist?(phase4_path)

      # Build event order map: {session_order => {event_key => event_order}}
      sessions = PhaseFileManager.new(phase4_path).data['sessions'] || []

      event_order_map = {}
      sessions.each do |session|
        session_order = session['session_order'].to_i
        event_order_map[session_order] ||= {}
        (session['events'] || []).each do |event|
          event_order_map[session_order][event['key']] = event['event_order'].to_i
        end
      end

      # Sort programs: individual first, then relay; within each group by session_order and event_order
      programs.sort_by do |prog|
        session_order = prog['session_order'].to_i
        event_code = prog['event_code'].to_s
        event_order = event_order_map.dig(session_order, event_code) || 9999
        is_relay = prog['relay'] ? 1 : 0

        [is_relay, session_order, event_order, prog['category_code'].to_s, prog['gender_code'].to_s]
      end
    rescue JSON::ParserError
      programs
    end
  end
end
