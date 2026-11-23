# frozen_string_literal: true

require 'date'
require 'pathname'
require 'json'

# = DataFixController: phased pipeline (v2)
#
# Split into per-phase controllers under app/controllers/data_fix/* in the
# A->B->C1 refactor; this class keeps only the cross-phase utility endpoints
# (coded-name and swimmer-teams lookups). The staging rows are purged per source from the
# Data-Fix sessions list (DataFix::SessionsListController, DataFix::StagingPurger).
class DataFixController < ApplicationController
  # [GET /data_fix/coded_name] (JSON only)
  # Computes the internal coded name for a Meeting ('code' target) or a SwimmingPool
  # ('nick_name' target). Used by +coded_name_controller.js+ in the Phase 1 forms.
  #
  # === Required options for Meeting's 'code' target:
  # - 'description' & 'city_name'
  #
  # === Required options for SwimmingPool's 'nick_name' target:
  # - 'name', 'city_name' & 'pool_type_code'
  #
  # == Returns:
  # A JSON response having format:
  #
  #    { <target> => <internal_coded_name> }
  #
  def coded_name
    unless request.format.json? && %w[code nick_name].include?(coded_name_params[:target])
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to root_path
      return
    end

    result = if coded_name_params[:target] == 'nick_name'
               GogglesDb::Normalizers::CodedName.for_pool(
                 coded_name_params[:name],
                 coded_name_params[:city_name],
                 coded_name_params[:pool_type_code]
               )
             else
               GogglesDb::Normalizers::CodedName.for_meeting(
                 coded_name_params[:description],
                 coded_name_params[:city_name]
               )
             end

    render(json: { coded_name_params[:target] => result })
  end

  # [GET /data_fix/teams_for_swimmer/:swimmer_id] (Turbo Stream only)
  # Renders the list of unique team names for which the specified swimmer has a badge,
  # updating the "team-list-for-<swimmer_id>" DOM target (empty text when none).
  #
  # == Params:
  # <tt>:swimmer_id</tt> => target Swimmer id (required)
  #
  def teams_for_swimmer
    unless request.format.turbo_stream?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to root_path
      return
    end

    @swimmer_id = teams_for_swimmer_params[:swimmer_id]
    @team_names = GogglesDb::Badge.where(swimmer_id: @swimmer_id)
                                  .includes(:team).joins(:team)
                                  .map { |row| "#{row.team.editable_name} (#{row.team_id})" }
                                  .uniq
                                  .join(', ')
  end

  private

  # Strong parameters checking for coded name retrieval.
  def coded_name_params
    params.permit(:target, :name, :city_name, :pool_type_code, :description)
  end

  # Strong parameters checking for team names list retrieval.
  def teams_for_swimmer_params
    params.permit(:swimmer_id)
  end
end
