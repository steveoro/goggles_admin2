# frozen_string_literal: true

module PdfManifests
  # = PdfManifests::ProgramScanner
  #
  #   - version:  7-0.10.60
  #   - author:   Devin
  #
  # Deterministic completeness heuristic for manifest extraction.
  # Scans the raw pdftotext output for event-like program mentions
  # ("200 sl", "Staff 4x50 sl mista") and reports the normalized codes
  # that the extracted LT4 event list does not cover (multiset diff).
  #
  # The result is a HINT list, never a hard error: false positives from
  # prose text are expected, so missing mentions are used only as
  # corrective-pass feedback and operator warnings.
  class ProgramScanner
    STROKE_WORDS = 'stile libero|farfalla|delfino|dorso|rana|mist[iao]|medley|stile|libero|mix|mx|sl|do|ra|fa|mi'
    INDIVIDUAL_RE = /\b(\d{2,4})\s*(?:m(?:etri)?\.?\s*)?(#{STROKE_WORDS})\b/i
    RELAY_STYLE_RE = /(\d+)\s*[x×]\s*(\d+)/i
    RELAY_HINT_RE = /staff|mistaf|saffett/i
    STROKE_WORD_RE = /\b(#{STROKE_WORDS})\b/i
    # Standalone "mista/misto" after a relay style marks mixed gender, not the stroke.
    GENDER_ONLY_RE = /\Amist[ao]\z/i

    # Returns labels of program mentions not covered by the extracted events,
    # e.g. ["100MI", "staffetta 4x50 sl"]. Empty when coverage is complete.
    def missing_mentions(manifest_text, extracted_events)
      individuals, relays = scan_mentions(manifest_text.to_s)
      have, have_relay = extracted_counts(extracted_events)
      missing_individuals(individuals, have) + missing_relays(relays, have_relay)
    end

    private

    # Multiset of normalized codes carried by the extracted LT4 events.
    # Relay prefixes (S same-gender / M mixed) are stripped so extracted
    # 'M4X50SL' matches the program mention '4x50 sl mista'.
    def extracted_counts(extracted_events)
      have = Hash.new(0)
      have_relay = Hash.new(0)
      Array(extracted_events).each do |event|
        code = event['eventCode'].to_s.upcase
        code.match?(/\A[SM]\d+X\d+/) ? have_relay[code[1..]] += 1 : have[code] += 1
      end
      [have, have_relay]
    end

    def missing_individuals(individuals, have)
      individuals.flat_map do |code, count|
        count > have[code] ? Array.new(count - have[code], code) : []
      end
    end

    def missing_relays(relays, have_relay)
      relays.flat_map do |label, count|
        uncovered = count - relay_coverage(label, have_relay)
        uncovered.positive? ? Array.new(uncovered, "staffetta #{label.downcase}") : []
      end
    end

    # Per-line scan: "NxM" tokens are collected as relay mentions, then stripped
    # so their leg length ("4x50 sl" -> 50 SL) is not double-counted as an
    # individual event on the same line.
    def scan_mentions(text)
      individuals = Hash.new(0)
      relays = Hash.new(0)
      text.each_line do |line|
        styles = []
        rest = line.gsub(RELAY_STYLE_RE) do
          styles << "#{::Regexp.last_match(1)}X#{::Regexp.last_match(2)}".upcase
          ' '
        end
        collect_relays(relays, styles, rest, line.match?(RELAY_HINT_RE))
        collect_individuals(individuals, rest)
      end
      [individuals, relays]
    end

    def collect_relays(relays, styles, rest, hinted)
      return if styles.empty?
      # Unhinted NxM tokens (no 'staffetta' wording) count only when a stroke
      # word follows, so venue text like "vasca 8x25" is ignored.
      return unless hinted || rest.match?(STROKE_WORD_RE)

      stroke = first_stroke(rest)
      styles.each { |style| relays[stroke ? "#{style}#{stroke}" : style] += 1 }
    end

    def collect_individuals(individuals, rest)
      rest.scan(INDIVIDUAL_RE) do |distance, stroke_word|
        code = individual_code(distance, stroke_word)
        individuals[code] += 1 if code
      end
    end

    def individual_code(distance, stroke_word)
      stroke = stroke_code(stroke_word)
      return unless stroke && Lt4Builder::VALID_DISTANCES.include?(distance.to_i)

      "#{distance.to_i}#{stroke}"
    end

    def stroke_code(word)
      Lt4Builder::STROKE_CODES[word.to_s.upcase] || (word.to_s.match?(/\Amix\z/i) ? 'MI' : nil)
    end

    # First stroke word found on the (relay-stripped) line, skipping bare
    # "mista/misto" which denote mixed gender rather than a stroke.
    def first_stroke(text)
      text.scan(STROKE_WORD_RE).flatten.each do |word|
        return stroke_code(word) unless word.match?(GENDER_ONLY_RE)
      end
      nil
    end

    # How many extracted relays cover the given mention. Strokeless mentions
    # ("4X50") are covered by any extracted relay sharing the style.
    def relay_coverage(label, have_relay)
      style = label[/\d+X\d+/]
      return have_relay[label].to_i if label.length > style.length

      have_relay.select { |code, _| code.start_with?(style) }.values.sum
    end
  end
end
