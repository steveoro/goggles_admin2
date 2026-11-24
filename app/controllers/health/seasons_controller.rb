# frozen_string_literal: true

module Health
  #
  # = Health::SeasonsController
  #
  # /health/seasons/:season_id: the data health of one season. The page lists one collapsible section per check
  # of the season's groups (a lazy 'health-section-<check>' frame each, see Health::SectionsController) under the
  # per-group run summary frame (#summary, with the "Re-run" buttons).
  #
  class SeasonsController < BaseController
    before_action :find_season!

    # GET /health/seasons/:season_id
    def show
      load_season_facts
      @check_counts = ops_available? ? Ops.safely({}) { check_counts } : {}
    end

    # GET /health/seasons/:season_id/summary (frame)
    def summary
      load_season_facts
      render_frame
    end

    private

    def load_season_facts
      @scope = Health::SeasonScope.new
      @entry = @scope.entry(@season.id)
      @overview = Health::Overview.new(scope: @scope)
      @groups = @entry&.groups.presence || []
      @cells = ops_available? ? Ops::HealthRun::GROUPS.index_with { |group| @overview.cell(@season.id, group) } : {}
    end

    # { check_key => { 'open' => { severity => n }, 'acknowledged' => n, 'ignored' => n } }
    def check_counts
      Ops::HealthFinding.for_season(@season.id).visible.group(:check_key, :status, :severity).count
                        .each_with_object({}) do |((check_key, status, severity), count), memo|
        entry = (memo[check_key] ||= { 'open' => Hash.new(0), 'acknowledged' => 0, 'ignored' => 0 })
        status == 'open' ? entry['open'][severity] += count : entry[status] += count
      end
    end
  end
end
