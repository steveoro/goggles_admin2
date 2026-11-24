# frozen_string_literal: true

#
# = HealthController
#
# /health: the closed-season data health matrix, one row per season, one column per check group (Meetings,
# Badges, People, Results, Setup) with the open error / warning counts and the latest run of each cell.
# "Local mirror": it reads the local MySQL DB (Health::SeasonScope) and the ops DB (Health::Overview) only.
#
# The page is a layout around the 'health-matrix' Turbo frame (#matrix), reloaded by live_frames_controller.js on
# the 'health-ping' broadcast (Health::Notifier) or every 20 s while a run is queued or running.
#
class HealthController < Health::BaseController
  # GET /health
  def index
    @include_no_data = params[:no_data] == '1'
    @last_sweep_at = Health::SweepJob.last_sweep_at if ops_available?
  end

  # GET /health/matrix (frame; no_data=1 lists the closed seasons without meetings and badges too)
  def matrix
    @overview = Health::Overview.new
    @include_no_data = params[:no_data] == '1'
    @rows = ops_available? ? @overview.rows(include_no_data: @include_no_data) : []
    @no_data_count = @overview.no_data_count
    render_frame
  end
end
