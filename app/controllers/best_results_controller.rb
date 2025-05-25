# frozen_string_literal: true

require 'csv'
require 'axlsx'

# = Best50mResultsController
#
# Retrieves the Best 50m results for the selected team and season.
#
class BestResultsController < ApplicationController # rubocop:disable Metrics/ClassLength
  before_action :authenticate_user! # Ensure user is logged in

  # GET /best_50m_results
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'Best50mResult')
  #
  # Note that "best timings" should be considered as having the swimmer as main
  # subject, regardless of the team they belonged to when that result was achieved.
  def best_50m
    prepare_params_and_dataset(GogglesDb::Best50mResult)
    handle_responders(@best_results, @team, 'best50m-3y', 'Best-50m-3y')
  end

  # GET /best_50_and_100
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'Best50And100Result')
  def best_50_and_100 # rubocop:disable Naming/VariableNumber
    prepare_params_and_dataset(GogglesDb::Best50And100Result)
    handle_responders(@best_results, @team, 'best50_and_100-3y', 'Best-50-and-100-3y')
  end

  # GET /best_50_and_100_5y
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'Best50And100Result')
  def best_50_and_100_5y
    prepare_params_and_dataset(GogglesDb::Best50And100Result) # TODO: Use new dedicated view GogglesDb::Best5y50And100Result
    handle_responders(@best_results, @team, 'best50_and_100-5y', 'Best-50-and-100-5y')
  end

  # GET /best_in_5y
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'BestSwimmer5yResult')
  def best_in_5y
    prepare_params_and_dataset(GogglesDb::BestSwimmer5yResult)
    handle_responders(@best_results, @team, 'best_5y', 'Best-5y')
  end

  # GET /all_time_best
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'BestSwimmerAllTimeResult')
  def all_time_best
    prepare_params_and_dataset(GogglesDb::BestSwimmerAllTimeResult)
    handle_responders(@best_results, @team, 'all_time_best', 'All-time-best')
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Prepares all the data parameters and the dataset for the views rendered by all actions in this controller.
  # (They all use the same parameters and result set)
  #
  def prepare_params_and_dataset(chosen_view)
    @team_id = params[:team_id]
    @results_by_swimmer = {}
    @best_results = []
    @team = nil

    if @team_id.present?
      @team = GogglesDb::Team.find_by(id: @team_id)
      swimmer_ids = @team.swimmers.pluck(:id)
      # Sets the @best_results and @results_by_swimmer instance variables:
      prepare_best_results(chosen_view, swimmer_ids)
    else
      # Initial load or parameters missing: Prepare for form display
      flash.now[:info] = I18n.t('best_results.info.select_team', default: 'Please select a team.')
    end
  end

  # Prepares the best results dataset for the specified view and swimmer IDs.
  #
  def prepare_best_results(chosen_view, swimmer_ids)
    if swimmer_ids.present?
      # Fetch results using the scope defined in goggles_db engine
      @best_results = chosen_view
                      .where(swimmer_id: swimmer_ids)
                      .includes(:event_type, :pool_type, :season, :meeting,
                                swimmer: [:gender_type, { badges: :category_type }],
                                season: [:federation_type, { season_type: :federation_type }]) # Eager load associations
                      .order('swimmers.last_name ASC', 'swimmers.first_name ASC', 'event_types.code ASC', 'pool_types.code ASC')
      # Group results by swimmer for HTML display
      @results_by_swimmer = @best_results.group_by(&:swimmer)
    else
      flash.now[:alert] = I18n.t('best_results.errors.invalid_selection', default: 'Invalid team selected.')
      @best_results = [] # Ensure it's an empty array for export formats if selection invalid
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # Handles the responses for the best results dataset.
  #
  def handle_responders(best_results, team, base_filename, base_title) # rubocop:disable Metrics/AbcSize
    respond_to do |format|
      format.html # index.html.haml (renders implicitly)
      format.csv do
        if team
          filename = "#{base_filename}_#{team.name.parameterize}.csv"
          csv_data = generate_csv_data(best_results)
          send_data csv_data, filename: filename, type: 'text/csv', disposition: 'attachment'
        else
          # Handle case where CSV is requested but team invalid or not selected
          flash[:alert] = I18n.t('best_results.errors.invalid_selection', default: 'Cannot export CSV without a valid team selection.')
          redirect_to best_50m_results_path # Redirect back to the HTML page
        end
      end

      format.xlsx do
        if team && best_results.present?
          filename = "#{base_filename}_#{team.name.parameterize}.xlsx"

          # Build workbook using helper method
          package = generate_best_result_xlsx_package(best_results, team, base_title)

          # Convert to stream and send
          xlsx_data = package.to_stream.read
          send_data(xlsx_data, filename: filename, type: Mime[:xlsx], disposition: 'attachment')

        else
          # Handle case where XLSX is requested but data is missing or selection invalid
          flash[:alert] =
            I18n.t('best_results.errors.invalid_selection_or_data',
                   default: 'Cannot export XLSX without a valid team selection, or no results found.')
          redirect_to best_50m_results_path # Redirect back to the HTML page
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # Generates the CSV data for the best results dataset specified.
  def generate_csv_data(best_results) # rubocop:disable Metrics/AbcSize
    CSV.generate(headers: true) do |csv|
      # Headers
      csv << %w[Swimmer Year Age Gender Category Event Pool Timing Meeting Date Season]
      # Data rows (using the non-grouped results)
      best_results.each do |result|
        csv << [
          result.swimmer.complete_name,
          result.swimmer.year_of_birth,
          result.swimmer.age,
          result.swimmer.gender_type&.label,
          result.swimmer.latest_category_type&.code,
          result.event_type.code,
          result.pool_type.code,
          result.to_timing,
          result.meeting.description,
          result.meeting.header_date,
          result.season.decorate.display_label
        ]
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # Generates the XLSX Package output for the best results dataset specified.
  def generate_best_result_xlsx_package(best_results, team, base_title) # rubocop:disable Metrics/AbcSize
    package = Axlsx::Package.new
    workbook = package.workbook

    # Define styles
    header_style = workbook.styles.add_style(b: true, sz: 12, bg_color: 'DDDDDD', alignment: { horizontal: :center })
    data_style   = workbook.styles.add_style(sz: 11)
    center_style = workbook.styles.add_style(sz: 11, alignment: { horizontal: :center })
    right_style  = workbook.styles.add_style(sz: 11, alignment: { horizontal: :right })

    workbook.add_worksheet(name: "#{base_title}-#{team.name.truncate(20)}") do |sheet|
      # Title row
      sheet.add_row ["#{base_title} #{team.name}"], style: header_style
      sheet.merge_cells 'A1:L1' # Merge title across columns (A to L)
      sheet.add_row # Blank row

      # Header row
      sheet.add_row %w[
        Swimmer ID Year Age Gender Category Event Pool Timing Meeting Date Season
      ], style: header_style

      # Data rows
      best_results.each do |result|
        sheet.add_row [
          result.swimmer.complete_name,
          result.swimmer_id,
          result.swimmer.year_of_birth,
          result.swimmer.age,
          result.swimmer.gender_type&.code,
          result.swimmer.latest_category_type&.code,
          result.event_type.code,
          result.pool_type.code,
          result.to_timing,
          result.meeting.description,
          result.meeting.header_date.to_s,
          result.season.decorate.short_label
        ], style: [data_style, right_style, right_style, right_style, center_style, right_style, right_style, center_style, right_style, data_style, center_style, data_style]
      end

      # Adjust column widths
      sheet.column_widths 40, 7, 6, 6, 6, 6, 6, 6, 10, nil, 15, nil
    end

    package
  end
  #-- -------------------------------------------------------------------------
  #++
end
