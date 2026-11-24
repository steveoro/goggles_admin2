# frozen_string_literal: true

module Health
  #
  # = Health::SectionsController
  #
  # /health/seasons/:season_id/sections/:check_key (Turbo frame 'health-section-<key>-frame'): the findings of one
  # check for one season (HealthFindingsGrid: status / severity / text filters, 50 per page) with the bulk triage form
  # (acknowledge, ignore with a note, reopen: Health::FindingsController#bulk) and the check how-to text.
  #
  class SectionsController < BaseController
    before_action :find_season!, :find_check!

    # GET /health/seasons/:season_id/sections/:check_key
    def show
      @frame_id = Health::SectionComponent.frame_id_for(@check.key)
      if ops_available?
        @grid = HealthFindingsGrid.new(grid_params) { |scope| scope.for_season(@season.id).for_check(@check.key) }
        @assets = @grid.assets.page(params[:page]).per(HealthFindingsGrid::PER_PAGE)
      end
      render_frame
    end

    private

    def find_check!
      @check = Health::Registry.find(params.expect(:check_key))
      head(:not_found) unless @check
    end

    def grid_params
      @grid_params ||= params.fetch(:health_findings_grid, {}).permit(:status, :severity, :search)
    end
    helper_method :grid_params
  end
end
