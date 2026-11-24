# frozen_string_literal: true

module Health
  #
  # = Health::BaseController
  #
  # Parent of the data health pages (HealthController and Health::*Controller). They read the local MySQL DB
  # ("local mirror") and the ops DB only; no API call. Not reachable from API-offline sessions
  # (api_offline_allowed? stays false), like every page that is not needed to fix the API connection.
  #
  class BaseController < ApplicationController
    protected

    # True when the ops DB is ready (memoized; the pages show a notice otherwise).
    def ops_available?
      return @ops_available if defined?(@ops_available)

      @ops_available = Ops.available?
    end
    helper_method :ops_available?

    # (before_action) The season of params[:season_id] (unscoped: no eager loading); a 404 when unknown.
    def find_season!
      @season = GogglesDb::Season.unscoped.find_by(id: params[:season_id])
      head(:not_found) unless @season
    end

    # Renders a Turbo frame response (no layout).
    def render_frame(template = nil)
      template ? render(template, layout: false) : render(layout: false)
    end

    # The local path given in params[:return_to] (never an external URL), or +fallback+.
    def safe_return_path(fallback)
      path = params[:return_to].to_s
      path.start_with?('/') && !path.start_with?('//') ? path : fallback
    end
  end
end
