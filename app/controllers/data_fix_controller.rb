# frozen_string_literal: true

require 'date'
require 'pathname'
require 'json'

# = DataFixController: phased pipeline (v2)
#
# Split into per-phase controllers under app/controllers/data_fix/* in the
# A->B->C1 refactor; this class keeps only the cross-phase utility endpoints
# that delegate to the legacy controller or wipe the staging tables.
class DataFixController < ApplicationController
  # Deletes all Data-Fix v2 temporary rows from data_import_* tables.
  # Intended as an operator "clean slate" action from dashboard.
  def purge
    session_count = GogglesDb::DataImportMeetingIndividualResult
                    .where.not(phase_file_path: [nil, ''])
                    .distinct
                    .count(:phase_file_path)

    deleted = {}
    ActiveRecord::Base.transaction do
      deleted[:laps] = GogglesDb::DataImportLap.delete_all
      deleted[:relay_laps] = GogglesDb::DataImportRelayLap.delete_all
      deleted[:relay_swimmers] = GogglesDb::DataImportMeetingRelaySwimmer.delete_all
      deleted[:relay_results] = GogglesDb::DataImportMeetingRelayResult.delete_all
      deleted[:individual_results] = GogglesDb::DataImportMeetingIndividualResult.delete_all
    end

    total_deleted = deleted.values.sum
    flash[:notice] =
      "Clean slate completed: removed #{total_deleted} temp rows across #{deleted.size} tables " \
      "(#{session_count} session(s) from phase_file_path)."
  rescue StandardError => e
    flash[:error] = "Clean slate failed: #{e.message}"
  ensure
    redirect_to(home_index_path)
  end

  # Shared read-only endpoints delegate to legacy for now
  def coded_name
    redirect_to controller: 'data_fix_legacy', action: 'coded_name', params: request.query_parameters
  end

  def teams_for_swimmer
    redirect_to controller: 'data_fix_legacy', action: 'teams_for_swimmer', params: request.query_parameters
  end
end
