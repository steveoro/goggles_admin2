# frozen_string_literal: true

module Health
  #
  # = Health::MatrixComponent
  #
  # The /health matrix: one row per season (Health::Overview::Row), one cell per check group with the open error /
  # warning counts (or "ack" when only acknowledged findings remain, "ok", "never run", a spinner while queued or
  # running, "failed" when the latest run failed), the latest run time and its duration. A cell opens the season page
  # on that group; the row has a "Re-run" button (every group of the season).
  #
  # Busy rows set data-live-busy="true" (live_frames_controller.js then polls every 20 s as a fallback).
  #
  class MatrixComponent < ViewComponent::Base
    GROUPS = Ops::HealthRun::GROUPS
    LEVEL_CSS = {
      error: 'text-danger-emphasis bg-danger-subtle', warning: 'text-warning-emphasis bg-warning-subtle',
      acknowledged: 'text-secondary-emphasis bg-secondary-subtle', info: 'text-info-emphasis bg-info-subtle',
      ok: 'text-success-emphasis', never: 'text-body-secondary', pending: 'text-info-emphasis', failed: 'text-danger-emphasis bg-danger-subtle'
    }.freeze
    STATUS_CSS = { current: 'text-bg-primary', closed: 'text-bg-secondary', upcoming: 'text-bg-info' }.freeze

    # == Params:
    # - rows: Array of Health::Overview::Row; include_no_data: the "no data" seasons are listed;
    # - no_data_count: number of "no data" seasons (for the show/hide link).
    def initialize(rows:, include_no_data: false, no_data_count: 0)
      super()
      @rows = rows
      @include_no_data = include_no_data
      @no_data_count = no_data_count
    end

    protected

    attr_reader :rows, :include_no_data, :no_data_count

    def busy? = rows.any?(&:pending?)

    def cell_css(cell) = "health-cell text-center #{LEVEL_CSS.fetch(cell.level, '')}".squish

    # Short text of a cell (with its title for the tooltip).
    def cell_text(cell)
      case cell.level
      when :error then "#{cell.errors} !"
      when :warning then "#{cell.warnings} ~"
      when :acknowledged then t('health.matrix.cell.ack', count: cell.acknowledged)
      when :info then t('health.matrix.cell.info', count: cell.infos)
      when :never then t('health.matrix.cell.never')
      when :failed then t('health.matrix.cell.failed')
      else t('health.matrix.cell.ok')
      end
    end

    def cell_title(cell)
      parts = [t('health.matrix.cell.title', errors: cell.errors, warnings: cell.warnings, infos: cell.infos,
                                             acknowledged: cell.acknowledged, ignored: cell.ignored)]
      parts << run_text(cell.run) if cell.run
      parts << t('health.matrix.cell.stale') if cell.stale
      parts.join(' · ')
    end

    def run_text(run)
      [t("health.run_statuses.#{run.status}"), short_time(run.finished_at), duration_text(run.duration_ms)].compact.join(' ')
    end

    def last_run_text(row)
      return t('health.matrix.never_run') unless row.last_run

      text = short_time(row.last_run.finished_at)
      row.unchanged? ? t('health.matrix.unchanged', time: text) : "#{text} (#{duration_text(row.duration_ms)})"
    end

    def duration_text(duration_ms)
      return if duration_ms.nil?

      seconds = duration_ms / 1000.0
      return format('%<seconds>.1fs', seconds:) if seconds < 60

      format('%<minutes>dm%<seconds>02ds', minutes: (seconds / 60).floor, seconds: (seconds % 60).floor)
    end

    def short_time(time)
      time ? l(time.localtime, format: :short) : '-'
    end

    def season_label(row)
      row.entry.no_data? ? t('health.season_statuses.no_data') : t("health.season_statuses.#{row.entry.status}")
    end

    def status_css(row)
      row.entry.no_data? ? 'bg-body-secondary text-body-secondary' : STATUS_CSS.fetch(row.entry.status, 'text-bg-secondary')
    end

    def cell_path(row, group)
      helpers.health_season_path(row.season_id, anchor: "health-group-#{group}")
    end

    def runnable?(row, group) = row.entry.groups.include?(group)
  end
end
