# frozen_string_literal: true

require 'date'
require 'pathname'
require 'json'

# = DataFixController: phased pipeline (v2)
#
# Split into per-phase controllers under app/controllers/data_fix/* in the
# A->B->C1 refactor; this class keeps only the cross-phase utility endpoints
# (coded-name and swimmer-teams lookups) and the staging-tables purge.
class DataFixController < ApplicationController
  # Deletes the Data-Fix v2 temporary rows from data_import_* tables.
  # Intended as an operator "clean slate" action from dashboard.
  #
  # === Params:
  # - :source_path => (optional) when given, deletes only the rows having that same
  #   +phase_file_path+; when missing, wipes everything.
  def purge
    source_path = params.key?(:source_path) ? params[:source_path].to_s : nil
    return unknown_source_path if source_path && !known_source_path?(source_path)

    session_count = GogglesDb::DataImportMeetingIndividualResult
                    .where.not(phase_file_path: [nil, ''])
                    .distinct
                    .count(:phase_file_path)

    deleted = source_path ? DataFix::StagingPurger.purge!(source_path) : DataFix::StagingPurger.purge_all!

    total_deleted = deleted.values.sum
    flash[:notice] = if source_path
                       I18n.t('data_import.data_fix.discard_source_done', total: total_deleted, source: source_path)
                     else
                       I18n.t('data_import.data_fix.clean_slate_done',
                              total: total_deleted, tables: deleted.size, sessions: session_count)
                     end
  rescue StandardError => e
    flash[:error] = I18n.t('data_import.data_fix.clean_slate_failed', message: e.message)
  ensure
    redirect_to(home_index_path)
  end

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

  # True when at least one staging row is bound to the given +phase_file_path+.
  def known_source_path?(source_path)
    DataFix::StagingPurger.known_source?(source_path)
  end

  # Polite refusal for a blank or unknown +source_path+.
  def unknown_source_path
    # (the redirect in #purge's ensure clause follows, so no flash.now)
    flash[:warning] = I18n.t('data_import.data_fix.discard_source_unknown') # rubocop:disable Rails/ActionControllerFlashBeforeRender
  end
end
