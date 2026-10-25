# frozen_string_literal: true

module CrawlerCalendar
  # = CrawlerCalendar::Row
  #
  #   - version:  7-0.10.63
  #   - author:   Devin
  #
  # Wraps a single CSV row of a FIN calendar file produced by
  # crawler/server/calendar-crawler.js, exposing the same derived fields the
  # results crawler computes plus the manifest/result artifact state on disk.
  #
  # The derived-field methods are FAITHFUL PORTS of the JavaScript originals
  # (crawler/server/utility.js + results-crawler.js) — including their quirks —
  # because the manifest filename produced by the crawler depends on them
  # byte-for-byte.
  #
  # == Expected CSV columns (see CrawlUtil.readCSVData):
  #   startURL,date,isCancelled,name,place,meetingUrl,year
  #
  class Row
    # Artifact base folders, relative to data_root:
    MANIFESTS_DIR = 'manifests'
    MANIFESTS_DONE_DIR = 'manifests.done'
    RESULTS_NEW_DIR = 'results.new'
    RESULTS_DONE_DIR = 'results.done'

    attr_reader :index, :csv_row, :season_id, :data_root

    def initialize(csv_row:, index:, season_id:, data_root: Rails.root.join('crawler/data'))
      @csv_row = csv_row
      @index = index
      @season_id = season_id
      @data_root = Pathname(data_root)
    end

    # -----------------------------------------------------------------
    # Raw CSV fields
    # -----------------------------------------------------------------

    def date
      csv_row['date']
    end

    def year
      csv_row['year']
    end

    def name
      csv_row['name'].to_s
    end

    def place
      csv_row['place'].to_s
    end

    def url
      csv_row['meetingUrl'].to_s
    end

    def raw_cancelled
      csv_row['isCancelled']
    end

    # -----------------------------------------------------------------
    # Derived fields (ports of crawler/server/results-crawler.js logic)
    # -----------------------------------------------------------------

    # TRUE only when the raw isCancelled column is exactly 'true' or 'canc'
    # (JS: row.isCancelled == 'true' || row.isCancelled == 'canc'). Any other
    # cell content — e.g. a localized "annullata" label — is NOT cancelled.
    def cancelled?
      %w[true canc].include?(raw_cancelled)
    end

    # TRUE when the crawler would process this row's URL.
    # JS check: calendarRow.url && calendarRow.url != 'undefined' &&
    #           calendarRow.url != 'null' && calendarRow.url != ' '
    # (' ' is rejected literally; a 2+ spaces string would pass the JS check,
    # so no .present?/.blank? shortcuts are used here.)
    def url?
      url != '' && url != 'undefined' && url != 'null' && url != ' '
    end

    # TRUE when the results crawler will actually fetch this row.
    def crawlable?
      url? && !cancelled?
    end

    # ISO dates list, same as CrawlUtil.readCSVData => dates.
    def dates
      @dates ||= self.class.parse_days_date(date, year)
    end

    # Port of results-crawler.js getOutputJSONFilename(calendarRow):
    #   dates is always an Array in CSV mode, so an empty list yields
    #   'undefined-<name>' (NOT 'xxx-'; that's direct-URL mode only).
    def manifest_basename
      "#{dates.first || 'undefined'}-#{self.class.normalize_text(name).gsub(/\s+/, '_')}"
    end

    def manifest_filename
      "manifest-#{manifest_basename}.pdf"
    end

    # -----------------------------------------------------------------
    # On-disk artifact state
    # -----------------------------------------------------------------

    # :done (pdf archived in manifests.done), :pending (downloaded, in
    # manifests/, not yet extracted) or :none.
    def manifest_state
      return :done if File.exist?(season_dir(MANIFESTS_DONE_DIR).join(manifest_filename))
      return :pending if File.exist?(season_dir(MANIFESTS_DIR).join(manifest_filename))

      :none
    end

    # :lt4 (extracted manifest source in results.new), :json (crawled results
    # JSON in results.new), :done (either moved to results.done), :none.
    def source_state
      return :done if File.exist?(season_dir(RESULTS_DONE_DIR).join("#{manifest_basename}-lt4.json")) ||
                      File.exist?(season_dir(RESULTS_DONE_DIR).join("#{manifest_basename}.json"))
      return :lt4 if File.exist?(season_dir(RESULTS_NEW_DIR).join("#{manifest_basename}-lt4.json"))
      return :json if File.exist?(season_dir(RESULTS_NEW_DIR).join("#{manifest_basename}.json"))

      :none
    end

    # -----------------------------------------------------------------
    # Faithful ports of crawler/server/utility.js helpers
    # -----------------------------------------------------------------

    # Port of CrawlUtil.normalizeText(). Converts word-ending apostrophes to
    # accented vowels, collapses whitespace, strips CSV/JSON-hostile chars.
    # ('°' and other symbols are kept on purpose, as in the JS version.)
    def self.normalize_text(text)
      return '' if text.nil?

      text.strip.gsub(/\r?\n/i, '; ')
          .gsub(/a'(?!\w)/i, 'à').gsub(/e'(?!\w)/i, 'è').gsub(/i'(?!\w)/i, 'ì')
          .gsub(/o'(?!\w)/i, 'ò').gsub(/u'(?!\w)/i, 'ù')
          .gsub(/\s+/, ' ')
          .gsub(%r{[*!£$%|/?<>"`]}i, '')
    end

    # Port of CrawlUtil.parseDaysDate(): given a 'DD(-DD)*/MM' days date (or a
    # '; '-separated/single ISO string) plus a 'YYYY' year, returns an Array of
    # 'YYYY-MM-DD' strings. Ported quirks:
    # - '31/10-8_11' => ['2026-10-8_11-31'] (FIN multi-month format oddity);
    # - '21-22/11'   => ['2026-11-21', '2026-11-22'];
    # - JS 'xx' placeholders for missing day/month tokens;
    # - JS padStart(4, '2000') => rjust(4, '2000').
    def self.parse_days_date(days_date, year) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      days_date = days_date.to_s
      year = year.to_s
      return [] if days_date.empty? || year.empty?

      return days_date.split('; ') if days_date.include?('; ')
      return [days_date] if days_date.include?('-') && days_date.exclude?('/')

      date_tokens = days_date.include?('/') ? days_date.split('/') : []
      days = date_tokens[0].present? ? date_tokens[0].split('-', -1) : []
      full_year = year.rjust(4, '2000')
      days.map do |day|
        s_month = date_tokens.size > 1 ? date_tokens[1].rjust(2, '0') : 'xx'
        s_day = day.present? ? day.rjust(2, '0') : 'xx'
        "#{full_year}-#{s_month}-#{s_day}"
      end
    end

    private

    def season_dir(base)
      data_root.join(base, season_id.to_s)
    end
  end
end
