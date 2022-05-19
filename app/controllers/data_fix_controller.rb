# frozen_string_literal: true

# = DataFixController: pre-production editing
#
# Allows review & edit of imported or crawled data before the push to production.
# (Legacy data-import step 1 & 2)
#
class DataFixController < ApplicationController
  # [POST] Loads the specified JSON file and starts parsing its contents in search of already existing
  # database rows.
  #
  # Whenever a corresponding row is found, the ID is added to the JSON object.
  # Missing rows will be prepared for later creation and the required attributes will be added to the JSON
  # object.
  # At the end of the process, the JSON object will be saved to the same file.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be loaded and scanned for existing rows.
  #
  def prepare_result_file
    if file_params[:file_path].blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    @file_path = file_params[:file_path]
    file_content = File.read(@file_path)
    @parsed_json = JSON.parse(file_content)

    # TODO: display progress in real time using another ActionCable channel? (or same?)

    # "layoutType"=>2,
    # "name"=>"Distanze Speciali Lazio", # => TODO meeting finder by name

    # "meetingURL"=>"https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/139716:distanze-speciali-lazio.html",
    # "manifestURL"=>"https://www.federnuoto.it/component/solrconnect/download.html?file=L3Zhci93d3cvZmluX2ZpbGVzL2V2ZW50aS8wMDAwMTM5NzE2LnBkZg==",

    # "dateDay1"=>"06", "dateMonth1"=>"Novembre", "dateYear1"=>"2021",
    # "dateDay2"=>"07", # => TODO Parser::SessionDate

    # "venue1"=>"STADIO DEL NUOTO - CIVITAVECCHIA", # => TODO Pool fuzzy finder

    # "address1"=>"VIALE LAZIO - LOC. SAN GORDIANO, 19 - Civitavecchia (RM)",
    # "venue2"=>"STADIO DEL NUOTO - CIVITAVECCHIA",
    # "address2"=>"VIALE LAZIO - LOC. SAN GORDIANO, 19 - Civitavecchia (RM)",

    # "poolLength"=>"50", # => almost as is

    # @parsed_json['sections'].each do |section|
    #   # sections[ {"title"=>"800 Stile Libero - M30", "fin_id_evento"=>"139716", "fin_codice_gara"=>"08",
    #   #          "fin_sigla_categoria"=>"M30", "fin_sesso"=>"M",
    #   #          "rows"=>[
    #   #             {"pos"=>"1", "name"=>"DIONISI MARCO", "year"=>"1992", "sex"=>"M", "team"=>"Polisport srl - C.Castell", "timing"=>"10:31.90", "score"=>"801,68"}
    #   #           ]}, ... ]
    #   # ...
    #   section['title'] # => TODO Parser::EventType (return base attributes)
    #   section['fin_sigla_categoria'] # => TODO Parser::CategoryType (return base attributes, given the season)
    #   section['fin_sesso'] # => as is
    #   section['rows'].each do |row|
    #     row['pos'] # => as is
    #     row['name'] # => GogglesDb::Swimmer.for_name(name) || for_complete_name || Fuzzy Swimmer finder TODO
    #     row['year'] # => as is
    #     row['sex'] # => as is
    #     row['team'] # => GogglesDb::Team.for_name(name) || Fuzzy Team finder TODO
    #     row['timing'] # => TODO Parser::Timing
    #     row['score'] # => TODO Parser::Score
    #   end
    # end
  rescue StandardError
    flash[:error] = I18n.t('data_import.errors.invalid_file_content')
    redirect_to(pull_index_path) && return
  end

  private

  # Strong parameters checking for file-related actions.
  def file_params
    params.permit(:file_path)
  end
end
