# frozen_string_literal: true

require 'csv'

# = PdfController:
#
# PDF > TXT > JSON conversion handling.
#
class PdfController < ApplicationController
  before_action :set_file_path, :format_families

  # [GET] Convert a given file (by pathname) to a processable TXT.
  #
  # Relies on the 'pdftotext' utility by the Poppler Developers: http://poppler.freedesktop.org
  # (Any other tool may be used in future, but currently running the utility is not parametrized.)
  #
  # To see if you have the converter already installed on path run a: 'which pdftotext'
  #
  # === Possible PDF formats supported so far:
  # All supported formats are listed in 'app/strategies/pdf_results/formats/*.yml'
  #
  def extract_txt
    system("pdftotext -layout #{@file_path} #{@txt_pathname}") unless File.exist?(@txt_pathname)

    file_contents = File.read(@txt_pathname)
    @page1 = file_contents.split("\f").first
  end
  #-- -------------------------------------------------------------------------
  #++

  # [XHR PUT] Scan a converted TXT file (by pathname) using the FormatParser to
  # detect which format family is best applicable.
  #
  def scan # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    unless request.xhr? && request.put? && @file_path.present?
      flash[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to(root_path) && return
    end

    logger.info("\r\n--> Scanning for valid formats... (limit_pages: #{@limit_pages})")
    fp = PdfResults::FormatParser.new(@txt_pathname, verbose_log: process_params['debug'], debug: process_params['debug'])
    fp.scan(ffamily_filter: process_params['ffamily'], limit_pages: @limit_pages)

    @checked_formats = fp.checked_formats
    @page_count = fp.pages.count
    @last_index = fp.page_index
    @last_result_fmt_name = fp.result_format_type
    @last_valid_scan = fp.last_valid_scan_per_format
    return if fp.result_format_type.blank?

    logger.info("\r\n--> Extracting data hash...")
    data_hash = fp.root_dao&.collect_data&.fetch(:rows, [])&.find { |hsh| hsh[:name] == 'header' }
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    l2 = PdfResults::L2Converter.new(data_hash, fp.season)
    logger.info('--> Checking null Teams row-by-row for possible replacements...')

    # ----------------------------------------------------------------------
    # NOTE: (LEAVE THIS HERE FOREVER)
    # The best way to show the data_hash hierarchy for debugging is uncommenting the pry above and use:
    #
    # > puts fp.root_dao.hierarchy_to_s
    #
    # If you spot a sub-tree which belongs multiple times to the wrong parent or is orphaned in another sub-tree
    # or is displayed at a wrong depth level, usually it's due to a wrong layout definition programme in one of
    # its applied YAML files.
    #
    # For instance:
    # - Don't define parent contexts for results as optional (required: false) unless strictly necessary.
    # - An "empty key" parent context like an optional "category" parenting several "results" will end up
    #   collecting all results, even for other different events, during the DAO#merge().
    # - The DAO#merge() is called repeatedly during the parsing and will also end up building duplicates
    #   for each sub-context found with an "empty key" parent.
    #
    # Check out the 'finlazio' layout family for an example.
    # ----------------------------------------------------------------------
    l2_hash = l2.to_hash
    scan_l2_data_hash_for_null_team_names(l2_hash)

    logger.info("\r\n--> Converting to JSON & saving...")
    FileUtils.mkdir_p(File.dirname(@json_pathname)) # Ensure existence of the destination path
    File.write(@json_pathname, l2_hash.to_json)
  end
  #-- -------------------------------------------------------------------------
  #++

  # [XHR PUT] Retrieves the log contents specified in params[:file_path].
  #
  def log_contents
    unless request.xhr? && request.put? && @file_path.present?
      flash[:warning] = I18n.t('search_view.errors.invalid_request')
      redirect_to(root_path) && return
    end

    @log_contents = Terminal.render(File.read(@log_pathname)).html_safe # rubocop:disable Rails/OutputSafety
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Strong parameters checking for single file processing actions.
  def process_params
    params.permit(:file_path, :ffamily, :start_page, :end_page, :debug)
  end

  # Setter for @file_path; expects the 'file_path' parameter to be present.
  # Sets also @api_url.
  def set_file_path # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
    @file_path = process_params[:file_path]

    # Prepare @limit_pages, either as a single page or as a range:
    # (<0 disables the range and uses a single integer; nil will act as "no limit")
    start_page = process_params[:start_page]
    end_page = process_params[:end_page]
    @limit_pages = if end_page.to_i.negative? && start_page.present?
                     start_page.to_i
                   elsif start_page.to_i.negative? && end_page.present?
                     end_page.to_i
                   elsif start_page.present? && end_page.present?
                     (start_page.to_i..end_page.to_i)
                   elsif start_page.present?
                     (start_page.to_i..)
                   elsif end_page.present?
                     (..end_page.to_i)
                   end

    @txt_pathname = @file_path&.gsub(/\.pdf|\.txt/i, '.txt')
    @log_pathname = @file_path&.gsub(/\.pdf|\.txt/i, '.log')
    @json_pathname = @file_path&.gsub('pdfs', 'results.new')
                               &.gsub(/\.pdf|\.txt/i, '.json')
    return if @file_path.present?

    flash[:warning] = I18n.t('data_import.errors.invalid_request')
    redirect_to(pull_result_files_path(filter: '*.pdf', parent_folder: 'pdfs'))
  end

  # Collects all available main format files from app/strategies/pdf_results/formats/*.yml
  # mapping all format family names.
  #
  # Given a subset of YML sub-format files, each one distinguished in naming convention
  # by a common prefix followed by a different appendix separated by a dot ('.'),
  # the "format family" name is the common shared part of the file basename.
  # (E.g.: '1-ficr1.100m.yml' => frm.family: '1-ficr1'.)
  #
  # Returns an array of string file basenames.
  def format_families
    @format_families ||= Rails.root.glob('app/strategies/pdf_results/formats/*.yml')
                              .sort
                              .map { |fname| fname.basename.to_s.split('.').first }
                              .uniq
  end
  #-- -------------------------------------------------------------------------
  #++

  # Scans each row in each 'rows' array in each section from the specified data hash (in L2 format)
  # in search of any possible null team names inside each row result.
  #
  # Whenever a team name is found blank, another full scan is performed in search of a possible matching
  # result with a non-blank team name. These scans are performed only on the data structure itself,
  # without any DB involvement.
  #
  # Note that an actual DB scan to correct null team names can only be performed later on by the MacroSolver,
  # once all bindings with actual database-stored entities have been processed (namely, the Meeting, all Swimmers,
  # all Teams and all related MIRs).
  #
  # Substitution of the team name is performed "in place", directly on the data hash itself.
  # (So it needs to be stored afterwards.)
  #
  # Returns the specified <tt>l2_hash</tt> instance.
  def scan_l2_data_hash_for_null_team_names(l2_hash)
    # Scan each row in search of null Team names:
    l2_hash.fetch('sections', []).each do |sect|
      sect.fetch('rows', []).each do |row|
        # Bail out unless we have parameters for matching a team name:
        next if row['name'].blank? || row['year'].blank? || row['team'].present?

        # Scan recursively from the start, each row, in search of a possible matching team name
        possible_team = scan_l2_data_hash_for_a_matching_team_name(
          sections_list: l2_hash.fetch('sections', []),
          swimmer_name: row['name'], swimmer_year: row['year'], swimmer_sex: row['sex']
        )
        if possible_team.blank?
          $stdout.write('.') # (no replacement found) # rubocop:disable Rails/Output
          next
        end

        row['team'] = possible_team
        $stdout.write("\033[1;33;32m+\033[0m") # (team replaced!) # rubocop:disable Rails/Output
      end
    end
    l2_hash
  end

  # Scans each row in each 'rows' list from the specified array of section data hashes (already in L2 format)
  # in search of a result row matching the specified swimmer name, year and sex where team name is not blank.
  # Returns the found team name or +nil+ otherwise.
  def scan_l2_data_hash_for_a_matching_team_name(sections_list:, swimmer_name:, swimmer_year:, swimmer_sex:)
    sections_list.each do |sect|
      matching_row = sect.fetch('rows', []).detect do |row|
        row['name'] == swimmer_name && row['year'] == swimmer_year &&
          row['sex'] == swimmer_sex && row['team'].present?
      end
      return matching_row['team'] if matching_row
    end
    nil
  end
end
