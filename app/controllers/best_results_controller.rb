# frozen_string_literal: true

require 'csv'
require 'axlsx'
require 'ostruct'

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

  # GET /best_in_3y
  # Displays the best timings results for all the swimmers currently belonging to the selected team,
  # among the range of years defined by the corresponding "Best result" view. (In this case 'BestSwimmer5yResult')
  def best_in_3y
    prepare_params_and_dataset(GogglesDb::BestSwimmer3yResult)
    handle_responders(@best_results, @team, 'best_3y', 'Best-3y')
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

  # GET/POST /goggles_cup_preview
  # 3-phase GogglesCup preview page:
  # Phase 1 (GET without team_id): Select team
  # Phase 2 (GET with team_id): Select swimmers from team with toggle switches
  # Phase 3 (POST with team_id and swimmer_ids): Compute and display ranking
  def goggles_cup_preview # rubocop:disable Metrics/PerceivedComplexity
    @team_id = params[:team_id]
    @team = @team_id.present? ? GogglesDb::Team.find_by(id: @team_id) : nil
    @swimmers_for_team = []
    @selected_swimmer_ids = params[:swimmer_ids] || []
    @ranking_data = []

    if request.post?
      # Phase 3: Compute ranking
      if @team && @selected_swimmer_ids.present?
        compute_goggles_cup_ranking
        handle_goggles_cup_responders
      else
        flash.now[:alert] = I18n.t('goggles_cup.errors.invalid_selection', default: 'Please select a team and at least one swimmer.')
        # Fall through to phase 2 display
        prepare_swimmers_for_team
      end
    elsif @team
      # Phase 2: Show swimmer selection list
      prepare_swimmers_for_team
    else
      # Phase 1: Initial load - show team selection
      flash.now[:info] = I18n.t('goggles_cup.info.select_team', default: 'Please select a team.')
    end
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
        ], style: [data_style, right_style, right_style, right_style, center_style, right_style,
                   right_style, center_style, right_style, data_style, center_style, data_style]
      end

      # Adjust column widths
      sheet.column_widths 40, 7, 6, 6, 6, 6, 6, 6, 10, nil, 15, nil
    end

    package
  end
  #-- -------------------------------------------------------------------------
  #++

  # Prepares the list of swimmers for the selected team (Phase 2).
  #
  def prepare_swimmers_for_team
    @swimmers_for_team = GogglesDb::BestSwimmerCurrentVsPreviousResult
                         .where(team_id: @team_id)
                         .pluck(:swimmer_id, :swimmer_name, :swimmer_year_of_birth)
                         .map { |id, name, yob| ::OpenStruct.new(swimmer_id: id, swimmer_name: name, swimmer_year_of_birth: yob) }
                         .uniq(&:swimmer_id)
                         .sort_by(&:swimmer_name)
  end

  # Computes the GogglesCup ranking for selected swimmers (Phase 3).
  # For each swimmer:
  # - Calculate row_score = 1000 + (old_total_hundredths - total_hundredths) for each row
  # - Sort by row_score descending, take top 5 (or fewer)
  # - Sum top 5 row_scores as overall score
  # - Sort swimmers by overall score descending
  #
  def compute_goggles_cup_ranking # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    view_rows = GogglesDb::BestSwimmerCurrentVsPreviousResult
                .where(team_id: @team_id, swimmer_id: @selected_swimmer_ids)
                .includes(:event_type, :pool_type, :meeting)

    # Group by swimmer and compute scores
    swimmer_scores = view_rows.group_by(&:swimmer_id).map do |swimmer_id, rows|
      # Calculate row scores
      scored_rows = rows.map do |row|
        if row.old_total_hundredths.present? && row.old_total_hundredths.positive?
          improved_timing = row.old_total_hundredths - row.total_hundredths
          row_score = 1000 + improved_timing
        else
          row_score = 1000
        end
        {
          row: row,
          row_score: row_score
        }
      end

      # Sort by row_score descending, take top 5
      top_rows = scored_rows.sort_by { |sr| -sr[:row_score] }.first(5)

      # Sum top 5 row_scores as overall score
      overall_score = top_rows.sum { |sr| sr[:row_score] }

      {
        swimmer_id: swimmer_id,
        swimmer_name: rows.first.swimmer_name,
        swimmer_year_of_birth: rows.first.swimmer_year_of_birth,
        overall_score: overall_score,
        top_rows: top_rows
      }
    end

    # Sort swimmers by overall score descending
    @ranking_data = swimmer_scores.sort_by { |s| -s[:overall_score] }
  end

  # Handles responders for GogglesCup preview (HTML, CSV, XLSX).
  #
  def handle_goggles_cup_responders # rubocop:disable Metrics/AbcSize
    respond_to do |format|
      format.html # goggles_cup_preview.html.haml
      format.csv do
        if @team && @ranking_data.present?
          filename = "goggles_cup_#{@team.name.parameterize}.csv"
          csv_data = generate_goggles_cup_csv_data
          send_data csv_data, filename: filename, type: 'text/csv', disposition: 'attachment'
        else
          flash[:alert] = I18n.t('goggles_cup.errors.invalid_selection_or_data',
                                 default: 'Cannot export CSV without valid data.')
          redirect_to goggles_cup_preview_path
        end
      end

      format.xlsx do
        if @team && @ranking_data.present?
          filename = "goggles_cup_#{@team.name.parameterize}.xlsx"
          package = generate_goggles_cup_xlsx_package
          xlsx_data = package.to_stream.read
          send_data(xlsx_data, filename: filename, type: Mime[:xlsx], disposition: 'attachment')
        else
          flash[:alert] = I18n.t('goggles_cup.errors.invalid_selection_or_data',
                                 default: 'Cannot export XLSX without valid data.')
          redirect_to goggles_cup_preview_path
        end
      end
    end
  end

  # Generates CSV data for GogglesCup ranking (header data only).
  #
  def generate_goggles_cup_csv_data
    CSV.generate(headers: true) do |csv|
      csv << %w[Rank Swimmer Year_of_Birth Overall_Score Swimmer_ID]
      @ranking_data.each_with_index do |data, index|
        csv << [
          index + 1,
          data[:swimmer_name],
          data[:swimmer_year_of_birth],
          data[:overall_score],
          data[:swimmer_id]
        ]
      end
    end
  end

  # Generates XLSX package for GogglesCup ranking (header data only).
  #
  def generate_goggles_cup_xlsx_package
    package = Axlsx::Package.new
    workbook = package.workbook

    header_style = workbook.styles.add_style(b: true, sz: 12, bg_color: 'DDDDDD', alignment: { horizontal: :center })
    data_style = workbook.styles.add_style(sz: 11)
    right_style = workbook.styles.add_style(sz: 11, alignment: { horizontal: :right })

    workbook.add_worksheet(name: "GogglesCup-#{@team.name.truncate(20)}") do |sheet|
      sheet.add_row ["GogglesCup #{@team.name}"], style: header_style
      sheet.merge_cells 'A1:E1'
      sheet.add_row

      sheet.add_row %w[Rank Swimmer Year_of_Birth Overall_Score Swimmer_ID], style: header_style

      @ranking_data.each_with_index do |data, index|
        sheet.add_row [
          index + 1,
          data[:swimmer_name],
          data[:swimmer_year_of_birth],
          data[:overall_score],
          data[:swimmer_id]
        ], style: [right_style, data_style, right_style, right_style, right_style]
      end

      sheet.column_widths 6, 40, 10, 12, 8
    end

    package
  end
  #-- -------------------------------------------------------------------------
  #++
end
