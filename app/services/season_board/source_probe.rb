# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::SourceProbe
  #
  # Reads the facts the Season board needs from a JSON source file:
  # FIN event id (from the top-level 'meetingURL'/'manifestURL'), 'meeting_only' flag and
  # whether the file carries results.
  #
  # Files up to FULL_PARSE_MAX_BYTES are parsed in full when +full+ is requested (using
  # DataFix::SourceResolver#parsed_source_json & #source_result_free?); otherwise, only
  # bounded head/tail reads are used (URLs are near the top, '_meta' near the bottom),
  # and a large file is assumed to carry results unless flagged as 'meeting_only'
  # (a result-free source is never that large).
  #
  class SourceProbe
    FULL_PARSE_MAX_BYTES = 1024 * 1024
    CHUNK_BYTES = 64 * 1024

    URL_REGEXP_TEMPLATE = '"%s"\s*:\s*"((?:[^"\\\\]|\\\\.)*)"'
    MEETING_ONLY_REGEXP = /"meeting_only"\s*:\s*true/
    EMPTY_FACTS = { fin_event_id: nil, meeting_only: false, has_results: false }.freeze

    def initialize(source_resolver: DataFix::SourceResolver.new)
      @source_resolver = source_resolver
    end

    # Layout type detected from the content (2 when unknown).
    def layout_type(path)
      @source_resolver.detect_layout_type_from_content(path)
    end

    # Returns { fin_event_id: String|nil, meeting_only: bool, has_results: bool }.
    # With full: false, has_results is always false (not inspected).
    def call(path, full:)
      size = File.size(path)
      return probe_parsed(path) if full && size <= FULL_PARSE_MAX_BYTES

      head, tail = read_head_and_tail(path, size)
      meeting_only = MEETING_ONLY_REGEXP.match?(tail)
      {
        fin_event_id: FINEventId.parse_any(extract_url(head, 'meetingURL'), extract_url(head, 'manifestURL')),
        meeting_only:,
        has_results: full && !meeting_only
      }
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::SourceProbe] unreadable source #{path}: #{e.message}")
      EMPTY_FACTS.dup
    end

    private

    def probe_parsed(path)
      data = @source_resolver.parsed_source_json(path)
      return EMPTY_FACTS.dup unless data.is_a?(Hash)

      {
        fin_event_id: FINEventId.parse_any(data['meetingURL'], data['manifestURL']),
        meeting_only: data.dig('_meta', 'meeting_only') == true,
        has_results: !@source_resolver.source_result_free?(path)
      }
    rescue JSON::ParserError
      call(path, full: false)
    end

    def read_head_and_tail(path, size)
      File.open(path, 'rb') do |file|
        head = file.read(CHUNK_BYTES).to_s
        next [head, head] if size <= CHUNK_BYTES

        file.seek(-[CHUNK_BYTES, size - CHUNK_BYTES].min, IO::SEEK_END)
        [head, file.read.to_s]
      end
    end

    def extract_url(chunk, key)
      raw = chunk[Regexp.new(format(URL_REGEXP_TEMPLATE, key)), 1]
      return nil if raw.blank?

      JSON.parse(%("#{raw.dup.force_encoding(Encoding::UTF_8)}"))
    rescue JSON::ParserError
      nil
    end
  end
end
