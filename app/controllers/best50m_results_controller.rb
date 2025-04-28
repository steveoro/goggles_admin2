# frozen_string_literal: true

require 'csv'
require 'axlsx'

# = Best50mResultsController
#
# Retrieves the Best 50m results for the selected team and season.
#
class Best50mResultsController < ApplicationController # rubocop:disable Metrics/ClassLength
  before_action :authenticate_user! # Ensure user is logged in

  # GET /best_50m_results
  # Displays the best 50m results for the selected team and season.
  def index # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
    @team_id = params[:team_id]
    @season_id = params[:season_id]
    @results_by_swimmer = {}
    @best_50m_results = []
    @team = nil
    @season = nil
    @season_list = selectable_season_list

    if @team_id.present? && @season_id.present?
      @team = GogglesDb::Team.find_by(id: @team_id)
      @season = GogglesDb::Season.find_by(id: @season_id)

      if @team && @season
        # Fetch results using the scope defined in goggles_db engine
        @best_50m_results = GogglesDb::Best50mResult
                            .for_team_and_season_ids(@team.id, @season.id)
                            .includes(:event_type, :pool_type, :season, :meeting, swimmer: [:gender_type, { badges: :category_type }]) # Eager load associations, including category
                            .order('swimmers.last_name ASC', 'swimmers.first_name ASC', 'event_types.code ASC', 'pool_types.code ASC')
        # Group results by swimmer for HTML display
        @results_by_swimmer = @best_50m_results.group_by(&:swimmer)
      else
        flash.now[:alert] = I18n.t('best50m_results.errors.invalid_selection', default: 'Invalid team or season selected.')
        @best_50m_results = [] # Ensure it's an empty array for export formats if selection invalid
      end
    else
      # Initial load or parameters missing: Prepare for form display
      flash.now[:info] = I18n.t('best50m_results.info.select_team_season', default: 'Please select a team and season.')
    end

    # DEBUG:
    # Log registered handlers just before respond_to
    # Rails.logger.info("[Best50mResultsController#index] Registered handlers: #{ActionView::Template.template_handler_extensions.inspect}")

    respond_to do |format|
      format.html # index.html.haml (renders implicitly)
      format.csv do
        if @team && @season
          filename = "best50m_#{@team.name.parameterize}_#{@season.description.parameterize}.csv"
          csv_data = generate_csv_data(@best_50m_results)
          send_data csv_data, filename: filename, type: 'text/csv', disposition: 'attachment'
        else
          # Handle case where CSV is requested but team/season invalid or not selected
          flash[:alert] = I18n.t('best50m_results.index.errors.invalid_selection', default: 'Cannot export CSV without a valid team and season selection.')
          redirect_to best_50m_results_path # Redirect back to the HTML page
        end
      end

      format.xlsx do
        if @team && @season && @best_50m_results.present?
          filename = "best50m_#{@team.name.parameterize}_#{@season.description.parameterize}.xlsx"

          # Build workbook using helper method
          package = generate_best_50m_xlsx_package(@best_50m_results, @team, @season)

          # Convert to stream and send
          xlsx_data = package.to_stream.read
          send_data xlsx_data, filename: filename, type: Mime[:xlsx], disposition: 'attachment'

        else
          # Handle case where XLSX is requested but data is missing or selection invalid
          flash[:alert] =
            I18n.t('best50m_results.index.errors.invalid_selection_or_data',
                   default: 'Cannot export XLSX without a valid team and season selection, or no results found.')
          redirect_to best_50m_results_path # Redirect back to the HTML page
        end
      end
    end
  end

  private

  # Returns an array of selectable seasons IDs and labels, ready to be passed as static payload
  # for the AutoComplete component in the view.
  def selectable_season_list
    GogglesDb::Season.joins(:season_type).includes(:season_type)
                     .for_season_type(GogglesDb::SeasonType.mas_fin)
                     .where("begin_date > '2012-01-01'")
                     .by_begin_date(:desc).map do |season|
      year1 = season.begin_date.year
      year2 = season.end_date.year
      {
        id: season.id,
        season_label: season.decorate.display_label,
        description: season.description,
        year_text: "#{year1}/#{year2}"
      }
    end
  end

  # Generates the CSV data for the best_50m_results dataset.
  def generate_csv_data(best_50m_results) # rubocop:disable Metrics/AbcSize
    CSV.generate(headers: true) do |csv|
      # Headers
      csv << %w[Swimmer Year Age Gender Category Event Pool Timing Meeting Date Season]
      # Data rows (using the non-grouped results)
      best_50m_results.each do |result|
        csv << [
          result.swimmer.complete_name,
          result.swimmer.year_of_birth,
          result.swimmer.age,
          result.swimmer.gender_type&.label,
          result.swimmer.latest_category_type&.code,
          result.event_type.code,
          result.pool_type.code,
          result.timing,
          result.meeting.description,
          result.meeting.header_date,
          result.season.decorate.display_label
        ]
      end
    end
  end

  # Generates the XLSX Package output for the best_50m_results dataset.
  def generate_best_50m_xlsx_package(best_50m_results, team, season) # rubocop:disable Metrics/AbcSize
    package = Axlsx::Package.new
    workbook = package.workbook

    # Define styles
    header_style = workbook.styles.add_style(b: true, sz: 12, bg_color: 'DDDDDD', alignment: { horizontal: :center })
    data_style   = workbook.styles.add_style(sz: 11)
    center_style = workbook.styles.add_style(sz: 11, alignment: { horizontal: :center })
    right_style  = workbook.styles.add_style(sz: 11, alignment: { horizontal: :right })

    workbook.add_worksheet(name: "Best 50m - #{team.name.truncate(20)}") do |sheet|
      # Title row
      sheet.add_row ["Best 50m Results for #{team.name} - Season #{season.description}"], style: header_style
      sheet.merge_cells 'A1:K1' # Merge title across columns (A to K)
      sheet.add_row # Blank row

      # Header row
      sheet.add_row %w[
        Swimmer Year Age Gender Category Event Pool Timing Meeting Date Season
      ], style: header_style

      # Data rows
      best_50m_results.each do |result|
        sheet.add_row [
          result.swimmer.complete_name,
          result.swimmer.year_of_birth,
          result.swimmer.age,
          result.swimmer.gender_type&.label,
          result.swimmer.latest_category_type&.code,
          result.event_type.code,
          result.pool_type.code,
          result.timing,
          result.meeting.description,
          result.meeting.header_date.to_s,
          result.season.decorate.display_label
        ], style: [data_style, center_style, center_style, center_style, center_style, center_style, center_style, right_style, data_style, center_style, data_style]
      end

      # Adjust column widths
      sheet.column_widths 40, 6, 6, 6, 6, 6, 6, 10, nil, 15, nil
    end

    package
  end
end
