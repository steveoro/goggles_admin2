# frozen_string_literal: true

module DataFix
  # = DataFix::SessionsListController
  #
  # Lists the Data-Fix sessions (one per source: phase files and/or import staging rows) with a
  # "Resume" link and a per-source "Purge staging rows" action.
  # (Not to be confused with DataFix::SessionsController, which is the Phase 1 review.)
  class SessionsListController < ApplicationController
    # Review page (route helper + params flag) for each highest phase.
    RESUME_STEPS = { 1 => :review_sessions_path, 2 => :review_teams_path, 3 => :review_swimmers_path,
                     4 => :review_events_path, 5 => :review_results_path }.freeze

    helper_method :resume_path_for

    # [GET /data_fix/sessions]
    def index
      @rows = DataFix::SessionIndex.new.rows
    end

    # [DELETE /data_fix/sessions/purge] Deletes the staging rows of a single source.
    #
    # == Params:
    # - source_path: the +phase_file_path+ of the staging rows.
    def purge
      source_path = params[:source_path].to_s
      if DataFix::StagingPurger.known_source?(source_path)
        deleted = DataFix::StagingPurger.purge!(source_path)
        flash[:notice] = I18n.t('data_import.data_fix.discard_source_done', total: deleted.values.sum, source: source_path)
      else
        flash[:warning] = I18n.t('data_import.data_fix.discard_source_unknown')
      end
      redirect_to(data_fix_sessions_path)
    end

    private

    # Path of the review page for the row's highest phase (Phase 1 when none), or nil when the source file is gone.
    def resume_path_for(row)
      return unless row.source_exists?

      helper = RESUME_STEPS.fetch(row.highest_phase.clamp(1, 5))
      public_send(helper, file_path: row.source_path)
    end
  end
end
