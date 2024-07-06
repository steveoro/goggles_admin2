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
  # === Possible PDF formats found so far:
  # _WIP / Expanding:_
  # - "1-ficr1"       => FiCr.it 1 (url w/ variable footer on bottom)
  # - "1-ficr2"       => FiCr.it 2 (just a logo on top)
  # _STILL_TODO:_
  # - "2-goswim1"    => Go&Swim new (with logo/name on bottom)
  # - "2-goswim2"   => Go&Swim old (no name)
  # - "3-coni1"      => CONI dist. spec Lombardia
  # - "4-fin1"    => FIN new (ie Flegreo, SardiniaInWater)
  # - "4-fin2"      => FIN Veneto
  # - "4-fin3"     => FIN old (diff format)
  # - "5-dbmeeting"  => Firenze "DBMeeting" custom sw output (with lap timings, ie: results_2022-11-06_AmiciNuoto.txt)
  # - "6-fredianop"  => "F.Palazzi - Gestione manifestazioni nuoto Master" output
  # - "7-txt2pdf"     => custom TXT 2 PDF ()
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
    @last_valid_scan = fp.valid_scan_results
    return if fp.result_format_type.blank?

    logger.info('--> Extracting data hash...')
    data_hash = fp.root_dao&.data&.fetch(:rows, [])&.find { |hsh| hsh[:name] == 'header' }
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------

    l2 = PdfResults::L2Converter.new(data_hash, fp.season)
    logger.info('--> Converting to JSON & saving...')
    FileUtils.mkdir_p(File.dirname(@json_pathname)) # Ensure existence of the destination path
    File.write(@json_pathname, l2.to_hash.to_json)
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

    @log_contents = Terminal.render(File.read(@log_pathname)).html_safe
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
end
