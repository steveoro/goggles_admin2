# frozen_string_literal: true

module PdfResults
  #
  # = PdfResults::ScanRunner
  #
  # One scan of a results PDF (phase 15, run by PdfScanJob; formerly the synchronous PdfController#scan):
  #
  # 1. extracts the TXT with 'pdftotext -layout' (array form of #system: no shell) unless it exists already;
  # 2. runs the FormatParser on it (optional format family filter, page range and debug log), which writes its log
  #    next to the TXT;
  # 3. on a recognised format, converts the parsed data to the LT2 hash (L2Converter), fills the blank team names
  #    of a swimmer from another of their rows (no DB involved: the Data-Fix solvers do the rest) and writes
  #    'results.new/<season>/<base>.json'.
  #
  # Only PDFs in 'pdfs/<numeric season>/' of the data root are scanned (FormatParser takes the season from the parent
  # folder and would fall back to season 222 otherwise): any other path raises Refused.
  #
  class ScanRunner
    FORMATS_GLOB = 'app/strategies/pdf_results/formats/*.yml'

    # A PDF outside 'pdfs/<numeric season>/'.
    class Refused < StandardError; end

    Result = Data.define(:checked_formats, :page_count, :last_index, :result_format_type, :last_valid_scan, :json_path,
                         :log_path, :txt_path, :season_id) do
      # A recognised format parsed every page.
      def full_parse? = result_format_type.present? && last_index.to_i >= page_count.to_i
    end

    # The format family names (the YAML basenames before their first '.', e.g. '1-ficr1' for '1-ficr1.100m.yml').
    def self.format_families
      @format_families ||= Rails.root.glob(FORMATS_GLOB).map { |path| path.basename.to_s.split('.').first }.uniq.sort.freeze
    end

    # True for a .pdf file whose parent is 'pdfs/<numeric season>' of +root+ (both real paths).
    def self.scannable?(path, root:)
      pathname = Pathname.new(path)
      pathname.extname.casecmp?('.pdf') && pathname.dirname.dirname == Pathname.new(root).join('pdfs') &&
        pathname.dirname.basename.to_s.match?(/\A\d+\z/)
    end

    # Pages to scan from the form values (as the former PDF page): a single page when the other end is negative,
    # a range, an open range, or nil (every page).
    def self.limit_pages(start_page, end_page) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      if end_page.to_i.negative? && start_page.present? then start_page.to_i
      elsif start_page.to_i.negative? && end_page.present? then end_page.to_i
      elsif start_page.present? && end_page.present? then (start_page.to_i..end_page.to_i)
      elsif start_page.present? then (start_page.to_i..)
      elsif end_page.present? then (..end_page.to_i)
      end
    end

    attr_reader :pdf_path, :txt_path, :json_path, :log_path, :season_id

    # - pdf_path: the PDF (real path); data_root: the 'crawler/data' folder (real path);
    # - ffamily: optional format family filter; start_page / end_page: optional page range; debug: verbose log.
    def initialize(pdf_path:, data_root:, ffamily: nil, start_page: nil, end_page: nil, debug: false) # rubocop:disable Metrics/ParameterLists
      @pdf_path = Pathname.new(pdf_path)
      @data_root = Pathname.new(data_root)
      raise Refused, "not a PDF in pdfs/<season>: #{pdf_path}" unless self.class.scannable?(@pdf_path, root: @data_root)

      @season_id = @pdf_path.dirname.basename.to_s.to_i
      @txt_path = @pdf_path.sub_ext('.txt')
      @log_path = @txt_path.dirname.join("#{@txt_path.basename.to_s.split('.').first}.log")
      @json_path = @data_root.join('results.new', @season_id.to_s, @pdf_path.basename.sub_ext('.json'))
      @ffamily = ffamily.presence
      @limit_pages = self.class.limit_pages(start_page, end_page)
      @debug = debug
    end

    # Returns a Result (raises on a missing pdftotext output or a parser error).
    def call
      extract_txt!
      parser = FormatParser.new(@txt_path.to_s, verbose_log: @debug, debug: @debug)
      parser.scan(ffamily_filter: @ffamily, limit_pages: @limit_pages)
      write_json!(parser) if parser.result_format_type.present?
      Result.new(checked_formats: parser.checked_formats, page_count: parser.pages.count, last_index: parser.page_index,
                 result_format_type: parser.result_format_type, last_valid_scan: parser.last_valid_scan_per_format,
                 json_path: (@json_path.to_s if parser.result_format_type.present?), log_path: @log_path.to_s,
                 txt_path: @txt_path.to_s, season_id: @season_id)
    end

    private

    # Runs pdftotext (no shell: the file names are separate arguments) unless the TXT exists.
    def extract_txt!
      return if @txt_path.file?

      system('pdftotext', '-layout', @pdf_path.to_s, @txt_path.to_s)
      raise "pdftotext produced no text for #{@pdf_path.basename} (is poppler-utils installed?)" unless @txt_path.file?
    end

    def write_json!(parser)
      header = parser.root_dao&.collect_data&.fetch(:rows, [])&.find { |hsh| hsh[:name] == 'header' } # rubocop:disable Style/SafeNavigationChainLength
      l2_hash = L2Converter.new(header, parser.season).to_hash
      fill_blank_team_names(l2_hash)
      FileUtils.mkdir_p(@json_path.dirname)
      File.write(@json_path, l2_hash.to_json)
    end

    # Fills in place each blank team name with the team of another row of the same swimmer (name, year, sex).
    def fill_blank_team_names(l2_hash)
      sections = l2_hash.fetch('sections', [])
      sections.each do |section|
        section.fetch('rows', []).each do |row|
          next if row['name'].blank? || row['year'].blank? || row['team'].present?

          team = matching_team_name(sections, row)
          row['team'] = team if team.present?
        end
      end
      l2_hash
    end

    def matching_team_name(sections, row)
      sections.each do |section|
        match = section.fetch('rows', []).detect do |other|
          other['name'] == row['name'] && other['year'] == row['year'] && other['sex'] == row['sex'] && other['team'].present?
        end
        return match['team'] if match
      end
      nil
    end
  end
end
