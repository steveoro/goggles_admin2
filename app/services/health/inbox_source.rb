# frozen_string_literal: true

module Health
  #
  # = Health::InboxSource
  #
  # Dashboard inbox ("Needs you") items of the data health report, read from the ops DB only (four grouped queries,
  # never one item per finding):
  # - one item per season and group with OPEN errors ("Season 252 · Meetings: 9 errors"), band :notice, the most
  #   frequent checks as detail => the season page on that group;
  # - one low-priority item for all the open warnings => /health;
  # - one item per (season, group) whose latest run failed, band :failed => the season page, plus "Re-run";
  # - one "health checks overdue" item (band :failed) when runs stay queued beyond Health::SeasonRunJob::STALE_AFTER, or
  #   when no run has finished for OVERDUE_AFTER (a 'maintenance' worker that never runs); nothing before the first run.
  #
  # Keys: 'health:<season>:<group>', 'health:warnings', 'health:failed:<season>:<group>', 'health:overdue'.
  # Texts: 'inbox.health.*' (config/locales/health.*.yml).
  #
  class InboxSource < Inbox::Source
    OVERDUE_AFTER = 8.days
    DETAIL_CHECKS = 3

    def self.key = :health

    def self.enabled?(context) = context.ops_available?

    def self.more_path = Rails.application.routes.url_helpers.health_path

    def items(context)
      @now = context.now
      counts = Ops::HealthFinding.open_status.group(:season_id, :group_key, :check_key, :severity).count
      error_items(counts) + [warnings_item(counts)].compact + failed_run_items + [overdue_item].compact
    end

    private

    def error_items(counts)
      errors = counts.select { |(_season, _group, _check, severity), _count| severity == 'error' }
      since = Ops::HealthFinding.open_status.errors.group(:season_id, :group_key).minimum(:first_seen_at)
      errors.group_by { |(season_id, group, _check, _severity), _count| [season_id, group] }.map do |(season_id, group), rows|
        total = rows.sum(&:last)
        item(key: "health:#{season_id}:#{group}", kind: :health_errors, band: :notice,
             title: t(:errors_title, season: season_id, group: I18n.t("health.groups.#{group}"), count: total),
             detail: check_detail(rows), subject: { season_id:, group: }, count: total,
             action: action(t(:open), url_helpers.health_season_path(season_id, anchor: "health-group-#{group}")),
             since: since[[season_id, group]] || @now)
      end
    end

    def warnings_item(counts)
      warnings = counts.select { |(_season, _group, _check, severity), _count| severity == 'warning' }
      return if warnings.empty?

      total = warnings.values.sum
      seasons = warnings.keys.map(&:first).uniq.size
      item(key: 'health:warnings', kind: :health_warnings, band: :notice, title: t(:warnings_title, count: total, seasons:),
           detail: check_detail(warnings.to_a), count: total, action: action(t(:open_report), url_helpers.health_path),
           since: Ops::HealthFinding.open_status.warnings.minimum(:first_seen_at) || @now)
    end

    def failed_run_items
      Ops::HealthRun.latest_by_season_and_group.values.select(&:failed?).map { |run| failed_run_item(run) }
    end

    def failed_run_item(run)
      group = I18n.t("health.groups.#{run.group_key}")
      item(key: "health:failed:#{run.season_id}:#{run.group_key}", kind: :health_run_failed, band: :failed,
           title: t(:failed_title, season: run.season_id, group:), detail: run.error_message.to_s.truncate(200),
           subject: { season_id: run.season_id, group: run.group_key },
           action: action(t(:open), url_helpers.health_season_path(run.season_id, anchor: "health-group-#{run.group_key}")),
           secondary_action: rerun_action(run), since: run.finished_at || @now)
    end

    # "Re-run" POST of the failed group (a read-only check: allowed from the inbox).
    def rerun_action(run)
      action(t(:rerun), url_helpers.health_runs_path, http_method: :post,
                                                      params: { season_id: run.season_id, group: run.group_key, return_to: url_helpers.root_path })
    end

    # Runs queued or running for longer than Health::SeasonRunJob::STALE_AFTER (no 'maintenance' worker picks them up), or no
    # run finished for OVERDUE_AFTER. Nothing before the first run (the dashboard card says "never ran").
    def overdue_item
      stuck_since = Ops::HealthRun.pending.where(created_at: ...(@now - Health::SeasonRunJob::STALE_AFTER)).minimum(:created_at)
      return overdue('health_stuck', :stuck_title, stuck_since) if stuck_since

      last = Ops::HealthRun.finished.maximum(:finished_at)
      overdue('health_overdue', :overdue_title, last) if last && last < @now - OVERDUE_AFTER
    end

    def overdue(kind, title_key, time)
      item(key: 'health:overdue', kind:, band: :failed, title: t(title_key, time: short_time(time)), detail: t(:overdue_detail),
           action: action(t(:open_report), url_helpers.health_path), since: time)
    end

    # "9 × Meetings without results, no source · 2 × ..." for the most frequent checks of +rows+ ([[key, count], ...]).
    def check_detail(rows)
      per_check = rows.each_with_object(Hash.new(0)) { |((_season, _group, check_key, _severity), count), memo| memo[check_key] += count }
      per_check.sort_by { |_key, count| -count }.first(DETAIL_CHECKS).map do |check_key, count|
        "#{count} × #{Health::Registry.find(check_key)&.title || check_key}"
      end.join(' · ')
    end
  end
end
