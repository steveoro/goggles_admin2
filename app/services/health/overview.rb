# frozen_string_literal: true

module Health
  #
  # = Health::Overview
  #
  # Read model of the data health matrix (/health), the season page summary and the dashboard card: per season
  # and group, the visible finding counts (Ops::HealthFinding) and the latest / pending runs (Ops::HealthRun).
  # Reads the ops DB only (three queries), plus the Health::SeasonScope when the rows are asked for.
  #
  class Overview
    # Counts and runs of one (season, group):
    # - errors, warnings, infos: OPEN findings per severity; acknowledged, ignored: findings in those statuses;
    # - run: latest finished Ops::HealthRun (or nil); pending: queued/running Ops::HealthRun (or nil);
    # - stale: the latest run was made on an older db_epoch (the local DB was restored since).
    Cell = Data.define(:season_id, :group_key, :errors, :warnings, :infos, :acknowledged, :ignored, :run, :pending, :stale) do
      def open_count = errors + warnings + infos
      def pending? = pending.present?
      def failed? = run&.failed? || false
      def never_run? = run.nil?

      # :pending, :failed, :never, :error, :warning, :acknowledged, :info or :ok (display priority order).
      def level
        return :pending if pending?
        return :failed if failed?
        return :never if never_run? && (open_count + acknowledged).zero?

        { error: errors, warning: warnings, acknowledged:, info: infos }.find { |_level, count| count.positive? }&.first || :ok
      end
    end

    # One matrix row: the SeasonScope::Entry, its Cells by group key, the latest finished run among its groups and
    # the total duration of the latest runs.
    Row = Data.define(:entry, :cells, :last_run, :duration_ms) do
      delegate :season_id, to: :entry
      def errors = cells.values.sum(&:errors)
      def warnings = cells.values.sum(&:warnings)
      def pending? = cells.values.any?(&:pending?)
      # True when every latest run was skipped (unchanged data stamp).
      def unchanged? = cells.values.filter_map(&:run).then { |runs| runs.any? && runs.all?(&:skipped?) }
    end

    GROUPS = Ops::HealthRun::GROUPS

    def initialize(scope: nil, db_epoch: nil)
      @scope = scope
      @db_epoch = db_epoch
    end

    def scope
      @scope ||= Health::SeasonScope.new
    end

    def db_epoch
      @db_epoch ||= Ops.safely(1) { Ops::Setting.db_epoch }
    end

    # Matrix rows, one per season of the scope (most recent first); "no data" seasons only when asked for.
    def rows(include_no_data: false)
      entries = include_no_data ? scope.entries : scope.runnable
      entries.map { |entry| row_for(entry) }
    end

    # The Row of one season (nil when unknown).
    def row(season_id)
      entry = scope.entry(season_id)
      entry && row_for(entry)
    end

    # The Cell of a (season, group), even without any finding or run.
    def cell(season_id, group_key)
      key = [season_id.to_i, group_key.to_s]
      counts = finding_counts.fetch(key, {})
      run = latest_runs[key]
      Cell.new(season_id: key.first, group_key: key.last, errors: counts.fetch(%w[open error], 0),
               warnings: counts.fetch(%w[open warning], 0), infos: counts.fetch(%w[open info], 0),
               acknowledged: status_total(counts, 'acknowledged'), ignored: status_total(counts, 'ignored'),
               run:, pending: pending_runs[key], stale: run.present? && run.db_epoch.to_i < db_epoch)
    end

    # Number of "no data" seasons (listed only on request).
    def no_data_count = scope.entries.count(&:no_data?)

    # Time of the last sweep heartbeat (or nil).
    delegate :last_sweep_at, to: :'Health::SweepJob'

    # { [season_id, group_key] => { [status, severity] => count } } of the visible findings.
    def finding_counts
      @finding_counts ||= Ops.safely({}) do
        Ops::HealthFinding.visible.group(:season_id, :group_key, :status, :severity).count
                          .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((season_id, group, status, severity), count), memo|
          memo[[season_id, group]][[status, severity]] = count
        end
      end
    end

    # { [season_id, group_key] => latest finished Ops::HealthRun }
    def latest_runs
      @latest_runs ||= Ops.safely({}) { Ops::HealthRun.latest_by_season_and_group }
    end

    # { [season_id, group_key] => pending Ops::HealthRun } (not stale)
    def pending_runs
      @pending_runs ||= Ops.safely({}) do
        Ops::HealthRun.pending.where(created_at: Health::SeasonRunJob::STALE_AFTER.ago..).order(:id)
                      .index_by { |run| [run.season_id, run.group_key] }
      end
    end

    private

    # Findings of a status, all severities (+counts+: { [status, severity] => n }).
    def status_total(counts, status)
      counts.sum { |(row_status, _severity), count| row_status == status ? count : 0 }
    end

    def row_for(entry)
      cells = entry_groups(entry).index_with { |group| cell(entry.season_id, group) }
      runs = cells.values.filter_map(&:run)
      Row.new(entry:, cells:, last_run: runs.max_by { |run| run.finished_at || run.created_at },
              duration_ms: runs.sum { |run| run.duration_ms.to_i })
    end

    # Every group is shown for a season (an upcoming season runs only 'setup': the other cells stay empty).
    def entry_groups(_entry) = GROUPS
  end
end
