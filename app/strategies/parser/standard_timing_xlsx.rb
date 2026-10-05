# frozen_string_literal: true

require 'roo'

module Parser
  #
  # = StandardTimingXlsx
  #
  #   - version:  7-0.10.53
  #   - author:   Steve A.
  #   - build:    20261005
  #
  # Extractor for the official StandardTiming tables distributed by FIN in XLSX format
  # (e.g. 'mst_tb_ind_2026-2027b.xlsx').
  #
  # Returns normalized rows shaped like the "format 1" CSV supported by the
  # 'import:standard_timings' rake task:
  #
  #   { 'category_code' => ..., 'fin_event_code' => ..., 'event_label' => ...,
  #     'gender' => ..., 'pool_type' => ..., 'timing' => ... }
  #
  # == Expected sheet layout
  # Header row (within the first HEADER_SCAN_ROWS rows) with aliases like:
  #   CATEGORIA|CATEG | COD GARA | GARA | SESSO | VASCA | ... | TEMPO PRINT | TEMPO (mmsscc)
  # Any other columns (KEY, MIN, SEC, CENT, ...) are ignored.
  #
  # == Sheet selection
  # If a single sheet contains rows for both pool types (25 & 50), only that sheet is used.
  # Otherwise all matching sheets are merged and de-duplicated by
  # (category_code, event_label, gender, pool_type); conflicting timings for the same
  # key are reported in #warnings.
  #
  # == Normalization
  # - gender: 'U' => 'M', 'D' => 'F' (anything else passes through for validation upstream);
  # - category_code: any 3-digit 'Mxxx' code (e.g. 'M100') => 'MA0' (FINA standard, 100+);
  #   additional explicit aliases can be added to CATEGORY_ALIASES;
  # - timing: 'TEMPO PRINT' is preferred; when missing, it's rebuilt from the
  #   'TEMPO (mmsscc)' digit column (e.g. '165627' => '16:56.27').
  #
  class StandardTimingXlsx # rubocop:disable Metrics/ClassLength
    attr_reader :file_path

    # Maximum number of leading rows scanned for the header signature
    HEADER_SCAN_ROWS = 3
    # Output key => list of accepted header labels (normalized: upcased & stripped)
    HEADER_ALIASES = {
      'category_code' => %w[CATEGORIA CATEG],
      'fin_event_code' => ['COD GARA'],
      'event_label' => ['GARA'],
      'gender' => ['SESSO'],
      'pool_type' => ['VASCA'],
      'timing_print' => ['TEMPO PRINT'],
      'timing_mmsscc' => ['TEMPO (MMSSCC)']
    }.freeze
    # Minimum set of mapped columns for a sheet to be considered readable
    REQUIRED_KEYS = %w[category_code event_label gender pool_type].freeze
    # PoolType codes expected to be found together inside a single complete sheet
    POOL_TYPE_CODES = %w[25 50].freeze
    # Italian-to-standard gender code translation
    GENDER_ALIASES = { 'U' => 'M', 'D' => 'F' }.freeze
    # Explicit category code overrides (checked after the generic 'Mxxx' => 'MA0' rule)
    CATEGORY_ALIASES = {}.freeze
    #-- -------------------------------------------------------------------------
    #++

    def initialize(file_path)
      @file_path = file_path.to_s
      @sheets_used = []
      @warnings = []
      @dupe_rows = 0
      @rows = nil
    end

    # Returns the normalized Array of Hash rows extracted from the workbook.
    # Raises a RuntimeError when no compatible sheet is found.
    def rows
      @rows ||= extract_rows
    end

    def sheets_used
      rows
      @sheets_used
    end

    def warnings
      rows
      @warnings
    end

    def dupe_rows
      rows
      @dupe_rows
    end
    #-- -------------------------------------------------------------------------
    #++

    private

    def extract_rows
      book = Roo::Spreadsheet.open(file_path)
      candidates = book.sheets.filter_map { |name| scan_sheet(book.sheet(name), name) }
      raise "No compatible sheet found in '#{file_path}'" if candidates.empty?

      complete = candidates.find { |c| covers_all_pools?(c[:rows]) }
      if complete
        @sheets_used = [complete[:name]]
        dedupe(complete[:rows])
      else
        @sheets_used = candidates.pluck(:name)
        dedupe(candidates.flat_map { |c| c[:rows] })
      end
    end

    # Returns { name:, rows: } when the sheet header matches the expected layout, nil otherwise.
    def scan_sheet(sheet, name)
      header_row = nil
      col_map = nil
      scan_end = [sheet.first_row + HEADER_SCAN_ROWS - 1, sheet.last_row].min
      (sheet.first_row..scan_end).each do |r|
        col_map = map_headers(sheet.row(r))
        if col_map
          header_row = r
          break
        end
      end
      return unless col_map

      data = []
      ((header_row + 1)..sheet.last_row).each do |r|
        cells = sheet.row(r)
        rec = normalize_row(cells, col_map)
        data << rec if rec
      end
      return if data.empty?

      { name: name, rows: data }
    end

    # Maps normalized output keys to column indexes; nil when required headers are missing.
    def map_headers(cells)
      map = {}
      cells.each_with_index do |raw, idx|
        label = raw.to_s.strip.upcase
        HEADER_ALIASES.each do |key, aliases|
          map[key] = idx if aliases.include?(label)
        end
      end
      return unless REQUIRED_KEYS.all? { |k| map.key?(k) } && (map['timing_print'] || map['timing_mmsscc'])

      map
    end

    # Builds the normalized row Hash; nil for fully blank rows.
    def normalize_row(cells, map)
      rec = {
        'category_code' => normalize_category(cells[map['category_code']]),
        'fin_event_code' => map['fin_event_code'] ? normalize_numeric_code(cells[map['fin_event_code']]) : nil,
        'event_label' => cells[map['event_label']].to_s.strip.squeeze(' '),
        'gender' => normalize_gender(cells[map['gender']]),
        'pool_type' => normalize_numeric_code(cells[map['pool_type']]),
        'timing' => timing_from(cells, map)
      }
      rec unless rec.values.all?(&:blank?)
    end

    def normalize_category(value)
      code = value.to_s.strip.upcase
      return code if code.blank?

      # FIN non-standard 3-digit codes (e.g. 'M100') => FINA standard 'MA0' (100+)
      code = 'MA0' if code.match?(/\AM\d{3}\z/)
      CATEGORY_ALIASES.fetch(code, code)
    end

    def normalize_gender(value)
      GENDER_ALIASES.fetch(value.to_s.strip.upcase) { value.to_s.strip.upcase }
    end

    # Normalizes integer-like codes stored either as numbers or strings
    # (e.g. 25.0 / '25.0' => '25'; '00' => '00').
    def normalize_numeric_code(value)
      return value.to_i.to_s if value.is_a?(Numeric)

      str = value.to_s.strip
      str.match?(/\A\d+\.0+\z/) ? str.to_i.to_s : str
    end

    # Returns the timing text: 'TEMPO PRINT' when present, otherwise rebuilt from
    # the '(m)msscc' digit column (e.g. '002484' => '0:24.84', '165627' => '16:56.27').
    def timing_from(cells, map)
      printed = cells[map['timing_print']].to_s.strip if map['timing_print']
      return printed if printed.present?

      return if map['timing_mmsscc'].nil?

      digits = normalize_numeric_code(cells[map['timing_mmsscc']]).gsub(/\D/, '')
      return if digits.blank?

      digits = digits.rjust(6, '0')
      "#{digits[0...-4].to_i}:#{digits[-4..-3]}.#{digits[-2..]}"
    end

    def covers_all_pools?(rows)
      POOL_TYPE_CODES.all? { |code| rows.any? { |r| r['pool_type'] == code } }
    end

    # Removes duplicate (category, event, gender, pool) rows keeping the first occurrence.
    # Same-key rows with different timings generate a warning.
    def dedupe(rows)
      seen = {}
      rows.each_with_object([]) do |rec, kept|
        key = rec.values_at('category_code', 'event_label', 'gender', 'pool_type')
        if seen.key?(key)
          if seen[key]['timing'] == rec['timing']
            @dupe_rows += 1
          else
            @warnings << "Conflicting timing for #{key.join('/')}: kept '#{seen[key]['timing']}', ignored '#{rec['timing']}'"
          end
          next
        end

        seen[key] = rec
        kept << rec
      end
    end
  end
end
