# frozen_string_literal: true

require 'csv'

# = PdfController:
#
# PDF > TXT > JSON conversion handling.
#
class PdfController < ApplicationController
  before_action :set_file_path

  # [GET] Convert a given file (by pathname) to a processable TXT.
  #
  def extract_txt
    system("pdftotext -layout #{@file_path} #{@txt_pathname}") unless File.exist?(@txt_pathname)

    file_contents = File.read(@txt_pathname)
    @page1 = file_contents.split("\f").first
    # DEBUG ----------------------------------------------------------------
    # binding.pry
    # ----------------------------------------------------------------------
    # TODO:
    # - show page1 as <pre> text on page before continuing
    # - detect possible format from page1
    # - show detected format from page1
    # - button to proceed with txt parser using factory on format
    #

    # Possible formats so far:
    # 1. Go&Swim new (with logo/name on bottom)
    # 2. Go&Swim old (no name)
    # 3. FiCr.it 1 (url on bottom)
    # 4. FiCr.it 2 (just a logo on top)
    # 5. CONI dist. spec Lombardia
    # 6. FIN new (ie Flegreo, SardiniaInWater)
    # 7. FIN Veneto
    # 8. FIN old (diff format)
    # 9. custom TXT 2 PDF ()
    # 10. Firenze "DBMeeting" custom sw output (with lap timings, ie: results_2022-11-06_AmiciNuoto.txt)
    # 11. "Frediano Palazzi - Gestione manifestazioni nuoto Master" output
  end
  #-- -------------------------------------------------------------------------
  #++

  # [POST] Parse a converted TXT file (by pathname) into the JSON format handled by
  # the DataFixController.
  #
  def export_json; end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Strong parameters checking for single file processing actions.
  def process_params
    params.permit(:file_path)
  end

  # Setter for @file_path; expects the 'file_path' parameter to be present.
  # Sets also @api_url.
  def set_file_path
    @file_path = process_params[:file_path]
    @txt_pathname = @file_path&.gsub('.pdf', '.txt')
    return if @file_path.present?

    flash[:warning] = I18n.t('data_import.errors.invalid_request')
    redirect_to(pull_result_files_path(filter: '*.pdf', parent_folder: 'pdfs'))
  end
end
