# frozen_string_literal: true

module Health
  #
  # = Health::DashboardCardComponent
  #
  # Dashboard card of the data health report: the open errors and warnings of the Season board season, "closed
  # seasons: N errors in M seasons", the queued/running runs and the time of the last sweep. Reads the ops DB (three
  # grouped queries) plus one primary-key query on the seasons with errors (closed or not).
  #
  class DashboardCardComponent < ViewComponent::Base
    # == Params:
    # - board_season: the Season board GogglesDb::Season (or nil); ops_available: false shows the setup hint only;
    # - now: reference time.
    def initialize(board_season:, ops_available: true, now: Time.current)
      super()
      @board_season = board_season
      @ops_available = ops_available
      @now = now
    end

    protected

    attr_reader :board_season, :now

    def ops_available? = @ops_available

    # { season_id => { 'error' => n, 'warning' => n } } of the open findings.
    def open_counts
      @open_counts ||= Ops.safely({}) do
        Ops::HealthFinding.open_status.where(severity: %w[error warning]).group(:season_id, :severity).count
                          .each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |((season_id, severity), count), memo|
          memo[season_id][severity] += count
        end
      end
    end

    def board_errors = board_season ? open_counts[board_season.id]['error'] : 0
    def board_warnings = board_season ? open_counts[board_season.id]['warning'] : 0

    # Closed seasons (end date past) with open errors: { season_id => errors }.
    def closed_errors
      @closed_errors ||= begin
        with_errors = open_counts.select { |season_id, counts| counts['error'].positive? && season_id != board_season&.id }
        closed_ids = with_errors.empty? ? [] : GogglesDb::Season.unscoped.where(id: with_errors.keys).where(end_date: ...now.to_date).pluck(:id)
        with_errors.slice(*closed_ids).transform_values { |counts| counts['error'] }
      end
    end

    def pending_count
      @pending_count ||= Ops.safely(0) { Ops::HealthRun.pending.where(created_at: Health::SeasonRunJob::STALE_AFTER.ago..).count }
    end

    def never_ran? = Ops.safely(true) { !Ops::HealthRun.finished.exists? }

    # +css+ when +count+ is positive, the muted text colour otherwise.
    def count_css(count, css) = count.positive? ? css : 'text-body-secondary'

    def last_sweep_text
      time = Health::SweepJob.last_sweep_at
      time ? t('health.last_sweep', time: l(time.localtime, format: :short)) : t('health.no_sweep_yet')
    end
  end
end
