# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::Lt4Builder
  #
  #   - version:  7-0.10.55
  #   - author:   Devin
  #
  # Normalizes the raw JSON hash extracted from a meeting manifest (via LLM)
  # into the "layoutType: 4" source format consumed by the phased data-import
  # wizard (Phase1Solver & EventSolver).
  #
  # This layer is deterministic: it validates and fixes the LLM output
  # (stroke codes, distances, relay codes, dates, session mapping) and collects
  # human-readable warnings for anything suspicious instead of trusting
  # the generated data blindly.
  #
  class Lt4Builder # rubocop:disable Metrics/ClassLength
    # Stroke label variants found in manifests -> canonical stroke code.
    STROKE_CODES = {
      'SL' => 'SL', 'STILE' => 'SL', 'LIBERO' => 'SL', 'STILE LIBERO' => 'SL',
      'DO' => 'DO', 'DR' => 'DO', 'DORSO' => 'DO',
      'RA' => 'RA', 'RANA' => 'RA',
      'FA' => 'FA', 'FARFALLA' => 'FA', 'DELFINO' => 'FA',
      'MI' => 'MI', 'MX' => 'MI', 'MISTI' => 'MI', 'MISTA' => 'MI', 'MISTO' => 'MI', 'MEDLEY' => 'MI'
    }.freeze

    STROKE_LABELS = {
      'SL' => 'Stile Libero', 'DO' => 'Dorso', 'RA' => 'Rana',
      'FA' => 'Farfalla', 'MI' => 'Misti'
    }.freeze

    VALID_DISTANCES = [25, 50, 100, 200, 400, 800, 1500, 3000, 5000].freeze
    VALID_POOL_LENGTHS = %w[25 33 50].freeze

    # Stroke words scanned inside raw labels. 'mix' is intentionally absent:
    # the labels use it only inside 'mista/mix mista' relay wordings.
    LABEL_STROKE_RE = /\b(stile libero|stile|libero|dorso|rana|farfalla|delfino|misti|misto|mista|mx|sl|do|ra|fa|mi)\b/i

    # Structured validation issue. `retriable` marks problems the model can
    # plausibly fix on a corrective pass by re-reading the source text
    # (unknown event codes, dropped/mangled events, missing dates); advisory
    # issues stay as operator-facing warnings only.
    Issue = Struct.new(:message, :retriable, :context, keyword_init: true)

    attr_reader :lt4_hash, :warnings, :issues

    # == Params
    # - extracted: Hash decoded from the LLM response
    # - pdf_path: source manifest pathname (used for filename/date cross-check)
    # - season_id: season ID (from the parent folder name)
    # - model: LLM model name (recorded in _meta)
    #
    def initialize(extracted:, pdf_path:, season_id:, model: nil)
      @src = extracted || {}
      @pdf_path = pdf_path.to_s
      @season_id = season_id
      @model = model
      @warnings = []
      @issues = []
      @lt4_hash = build
    end

    private

    # Records a warning message plus its structured Issue counterpart.
    def warn_issue(message, retriable: false, **context)
      @warnings << message
      @issues << Issue.new(message: message, retriable: retriable, context: context)
    end

    def build
      dates = normalized_dates
      check_filename_date(dates.first)

      out = {
        'layoutType' => 4,
        'meetingName' => normalized_name,
        'title' => normalized_name,
        'edition' => normalized_edition,
        'dates' => dates.join(','),
        'place' => place_label,
        'venueName' => @src['venue_name'],
        'venueAddress' => full_address,
        'cityName' => @src['city'],
        'poolLength' => normalized_pool_length,
        'maxIndividualEvents' => normalized_max_events,
        'manifestSessions' => dates.each_with_index.map { |d, i| { 'date' => d, 'session_order' => i + 1 } },
        'seasonId' => @season_id,
        'swimmers' => {},
        'teams' => {},
        'events' => build_events(dates),
        '_meta' => build_meta
      }
      out.compact!
      out
    end

    def normalized_name
      name = @src['meeting_name'].to_s.strip
      warn_issue('meeting_name missing') if name.blank?
      name.presence
    end

    def normalized_edition
      ed = @src['edition']
      return ed.to_i if ed.to_i.positive?

      # Fallback: parse ordinal from the meeting name ("25° Trofeo ...")
      @src['meeting_name'].to_s.match(/(\d+)\s*°/)&.[](1)&.to_i
    end

    def normalized_dates
      dates = Array(@src['dates']).filter_map do |d|
        Date.iso8601(d.to_s.strip)
      rescue StandardError
        warn_issue("unparseable date '#{d}'", retriable: true, field: 'dates', value: d)
        nil
      end.uniq.sort
      warn_issue('no meeting dates extracted', retriable: true, field: 'dates') if dates.empty?
      dates.map(&:iso8601)
    end

    # Warns when the first extracted date differs from the date embedded in
    # the manifest filename ('manifest-YYYY-MM-DD-...').
    def check_filename_date(first_date)
      fname_date = File.basename(@pdf_path)[/manifest-(\d{4}-\d{2}-\d{2})/, 1]
      return if fname_date.blank? || first_date.blank? || fname_date == first_date

      warn_issue("first extracted date (#{first_date}) != filename date (#{fname_date})",
                 field: 'dates', extracted: first_date, filename: fname_date)
    end

    def normalized_pool_length
      len = @src['pool_length_meters'].to_s.gsub(/\D/, '')
      return nil if len.blank?
      return len if VALID_POOL_LENGTHS.include?(len)

      warn_issue("unusual pool length '#{len}'", retriable: true, field: 'pool_length_meters', value: len)
      len
    end

    def normalized_max_events
      val = @src['max_individual_events'].to_i
      val.positive? ? val : nil
    end

    def place_label
      [@src['venue_name'], @src['address'], city_with_province].compact_blank.join(', ').presence
    end

    def city_with_province
      city = @src['city'].to_s.strip
      prov = @src['province'].to_s.strip.upcase
      return city if prov.blank?

      "#{city} (#{prov})".strip
    end

    # Full address string used for both display and City tokenization
    # (Parser::CityName expects the city name at the end / near a province code).
    def full_address
      [@src['address'], city_with_province].compact_blank.join(', ').presence
    end

    # Converts the extracted event list into LT4 'events' entries.
    # Sessions are mapped 1-per-date in chronological order.
    def build_events(dates) # rubocop:disable Metrics/AbcSize
      session_order_by_date = dates.each_with_index.to_h { |d, i| [d, i + 1] }
      orders = Hash.new(0)
      seen = Hash.new { |h, k| h[k] = [] }

      Array(@src['events']).filter_map do |ev|
        event_hash = normalize_event(ev)
        next if event_hash.nil?

        session_date = ev['session_date'].to_s.strip
        session_order = session_order_by_date[session_date] || 1
        if session_date.present? && session_order_by_date[session_date].nil?
          warn_issue("event '#{ev['raw_label']}' has unknown session date '#{session_date}', assigned to session 1",
                     retriable: true, raw_label: ev['raw_label'], session_date: session_date)
        end

        if seen[session_order].include?(event_hash['eventCode'])
          warn_issue("duplicate event '#{event_hash['eventCode']}' in session #{session_order} skipped",
                     retriable: true, code: event_hash['eventCode'], session_order: session_order)
          next
        end
        seen[session_order] << event_hash['eventCode']
        orders[session_order] += 1

        event_hash.merge(
          'sessionOrder' => session_order,
          'eventOrder' => orders[session_order],
          'dayPart' => normalize_day_part(ev['day_part']),
          'results' => []
        )
      end
    end

    # Normalizes a single extracted event hash into the LT4 event shape.
    # Returns nil when the event is unusable (missing distance/stroke).
    def normalize_event(item)
      raw_label = item['raw_label'].to_s.strip
      # Relay detection cannot trust the model's 'relay' flag alone (e.g. "200MX"
      # misti events are routinely flagged as relays): require explicit
      # staffetta wording or an 'NxM' style in the label/style fields.
      is_relay = raw_label.match?(/staff|saffett|mistaf/i) ||
                 item['relay_style'].to_s.match?(/\d+\s*[xX]\s*\d+/) ||
                 raw_label.match?(/\b\d+\s*[xX]\s*\d+\b/)

      return normalize_relay(item, raw_label) if is_relay

      distance = item['distance'].to_i
      unless VALID_DISTANCES.include?(distance)
        warn_issue("event '#{raw_label}' has invalid distance '#{item['distance']}' - skipped",
                   retriable: true, raw_label: raw_label, value: item['distance'])
        return nil
      end
      stroke = normalize_stroke(item['stroke'], raw_label)
      return nil if stroke.nil?

      code = "#{distance}#{stroke}"
      warn_unknown_event_type(code, relay: false, raw_label: raw_label)
      {
        'eventCode' => code,
        'eventLength' => distance.to_s,
        'eventStroke' => stroke,
        'eventDescription' => "#{distance} m #{STROKE_LABELS[stroke]}",
        'relay' => false
      }
    end

    # Normalizes a relay event. The LT4 consumers expect 'eventLength' to carry
    # the "NxM" pattern (e.g. "4X50"), not the total distance: EventSolver
    # rebuilds the event code as <S|M><N>X<len><STROKE>.
    def normalize_relay(item, raw_label) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      style = item['relay_style'].to_s.presence ||
              raw_label[/(\d+)\s*[xX]\s*(\d+)/, 0]&.gsub(/\s+/, '') # e.g. "4x50"
      if style.blank?
        warn_issue("relay '#{raw_label}' has no detectable style (NxM) - skipped",
                   retriable: true, raw_label: raw_label)
        return nil
      end
      style = style.upcase

      stroke = normalize_stroke(item['stroke'], raw_label, default: 'SL')
      return nil if stroke.nil?

      # Mixed relay (mistaffetta / staffetta mista / explicit X) gets the 'M'
      # event-code prefix; plain 'staffetta' stays same-gender ('S').
      mixed = item['gender'].to_s.upcase == 'X' || raw_label.match?(/mistaf/i)
      prefix = mixed ? 'M' : 'S'
      code = "#{prefix}#{style}#{stroke}"
      warn_unknown_event_type(code, relay: true, raw_label: raw_label)

      {
        'eventCode' => code,
        'eventLength' => style,
        'eventStroke' => stroke,
        'eventGender' => (mixed ? 'X' : nil),
        'eventDescription' => "Staffetta #{style.tr('X', 'x')} m #{STROKE_LABELS[stroke]}#{' (mista)' if mixed}",
        'relay' => true
      }.compact
    end

    # Resolves the stroke code, falling back to scanning the raw label when the
    # LLM field is missing (e.g. 'mistaffetta 4x50 stile libero' => SL).
    # When both are present but disagree (model filled the field with a stroke
    # from a neighbouring program line), emits a retriable mismatch issue.
    def normalize_stroke(value, raw_label, default: nil)
      field_stroke = STROKE_CODES[value.to_s.strip.upcase]
      label_stroke, check_stroke = label_strokes(raw_label)

      if field_stroke
        warn_stroke_mismatch(raw_label, field_stroke, check_stroke) if check_stroke && check_stroke != field_stroke
        return field_stroke
      end
      return label_stroke if label_stroke
      return default if default

      warn_issue("event '#{raw_label}' has unknown stroke '#{value}' - skipped",
                 retriable: true, raw_label: raw_label, value: value)
      nil
    end

    # Stroke words found inside the raw label => [fallback_stroke, check_stroke].
    # Trailing 'mista/misto' mixed-gender markers are dropped when a real stroke
    # word is present; a lone gender word stays usable as fallback but is too
    # ambiguous for the field cross-check (check_stroke = nil).
    def label_strokes(raw_label)
      hits = raw_label.upcase.scan(LABEL_STROKE_RE).flatten
      hits = hits.grep_v(/\AMIST[AO]\z/) if hits.size > 1
      return [nil, nil] if hits.empty?

      label_stroke = STROKE_CODES[hits.first]
      check = hits.size == 1 && hits.first.match?(/\AMIST[AO]\z/) ? nil : label_stroke
      [label_stroke, check]
    end

    def warn_stroke_mismatch(raw_label, field_stroke, check_stroke)
      warn_issue("event '#{raw_label}' label suggests stroke '#{check_stroke}' but field says '#{field_stroke}'",
                 retriable: true, raw_label: raw_label, field: 'stroke',
                 field_value: field_stroke, label_value: check_stroke)
    end

    def normalize_day_part(value)
      v = value.to_s.strip.downcase
      return 'morning' if v.match?(/morn|matt/)
      return 'afternoon' if v.match?(/after|pomer/)

      nil
    end

    def warn_unknown_event_type(code, relay:, raw_label: nil)
      return if GogglesDb::EventType.exists?(code: code, relay: relay)

      warn_issue("event code '#{code}' (relay=#{relay}) not found in event_types",
                 retriable: true, code: code, relay: relay, raw_label: raw_label)
    end

    def build_meta
      {
        'generated_by' => 'PdfManifests::Extractor',
        'model' => @model,
        'source_manifest' => @pdf_path,
        'extracted_at' => Time.now.utc.iso8601,
        'meeting_only' => true,
        'warnings' => @warnings
      }
    end
  end
end
