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
  PURGE_TABLES = {
    laps: GogglesDb::DataImportLap,
    relay_laps: GogglesDb::DataImportRelayLap,
    relay_swimmers: GogglesDb::DataImportMeetingRelaySwimmer,
    relay_results: GogglesDb::DataImportMeetingRelayResult,
    individual_results: GogglesDb::DataImportMeetingIndividualResult
  }.freeze

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

    deleted = {}
    ActiveRecord::Base.transaction do
      PURGE_TABLES.each do |key, table|
        scope = source_path ? table.where(phase_file_path: source_path) : table
        deleted[key] = scope.delete_all
      end
    end

    total_deleted = deleted.values.sum
    record_purge_event(source_path, deleted)
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

  # Shared read-only endpoints delegate to legacy for now
  def coded_name
    redirect_to controller: 'data_fix_legacy', action: 'coded_name', params: request.query_parameters
  end

  def teams_for_swimmer
    redirect_to controller: 'data_fix_legacy', action: 'teams_for_swimmer', params: request.query_parameters
  end

  private

  # Appends the 'datafix.purged' event to the ops log (never raises).
  def record_purge_event(source_path, deleted)
    Ops.safely do
      Ops.record_event!(
        kind: 'datafix.purged', level: 'info', actor: 'operator',
        season_id: source_path && Integer(File.basename(File.dirname(source_path)), exception: false),
        subject_type: source_path ? 'source' : nil,
        subject_key: source_path,
        data: { 'scope' => source_path || 'all', 'deleted' => deleted.transform_keys(&:to_s) }
      )
    end
  end

  # True when at least one staging row is bound to the given +phase_file_path+.
  def known_source_path?(source_path)
    source_path.present? && PURGE_TABLES.values.any? { |table| table.exists?(phase_file_path: source_path) }
  end

  # Polite refusal for a blank or unknown +source_path+.
  def unknown_source_path
    # (the redirect in #purge's ensure clause follows, so no flash.now)
    flash[:warning] = I18n.t('data_import.data_fix.discard_source_unknown') # rubocop:disable Rails/ActionControllerFlashBeforeRender
  end
end
