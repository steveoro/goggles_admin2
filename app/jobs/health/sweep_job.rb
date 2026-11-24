# frozen_string_literal: true

module Health
  #
  # = Health::SweepJob
  #
  # Hourly heartbeat of the data health report (recurring task 'health_sweep', config/recurring.yml, minute 45),
  # on the 'maintenance' worker. Solid Queue does not replay the recurring runs missed while the machine was off,
  # so the heartbeat itself decides what is due from the Ops::HealthRun rows (a 'skipped' run counts as done):
  # - current and upcoming seasons: each group once a day, at the first heartbeat after DAILY_AT (06:30, after
  #   the 05:15 'season_board_recheck');
  # - closed seasons (with data): when any group's last run is older than CLOSED_INTERVAL (7 days); at most one
  #   closed season per heartbeat, and none while the runs of a closed season are still pending, so that the
  #   queue never floods. Their heavy groups run with <tt>skip_unchanged: true</tt> (Health::Stamp).
  # Pending runs older than Health::SeasonRunJob::STALE_AFTER are marked failed first.
  #
  # Only enqueues Health::SeasonRunJob (read-only checks): never writes meetings, calendars or any MySQL row.
  #
  class SweepJob < ApplicationJob
    queue_as :maintenance

    limits_concurrency key: 'health_sweep', to: 1, duration: 15.minutes, on_conflict: :discard

    DAILY_AT = '06:30'
    CLOSED_INTERVAL = 7.days
    # Time of the last heartbeat (Ops::Setting, ISO 8601 String).
    LAST_SWEEP_KEY = 'health.last_sweep_at'

    # Time of the last heartbeat (or nil). Never raises.
    def self.last_sweep_at
      value = Ops.safely { Ops.available? ? Ops::Setting.fetch(LAST_SWEEP_KEY) : nil }
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    # == Params:
    # - now: reference time (default: Time.current); scope: Health::SeasonScope (default: a new one for now's date).
    # Returns { daily: [Ops::HealthRun], closed_season_id: Integer or nil } (an empty Hash without ops DB).
    def perform(now: nil, scope: nil)
      return {} unless Ops.available?

      @now = now || Time.current
      @scope = scope || Health::SeasonScope.new(today: @now.to_date)
      Health::SeasonRunJob.fail_stale_runs!(now: @now)
      @last_ok = last_ok_runs
      daily = enqueue_daily
      closed = enqueue_closed
      Ops::Setting.store!(LAST_SWEEP_KEY, @now.utc.iso8601)
      { daily:, closed_season_id: closed }
    end

    private

    # { [season_id, group_key] => finished_at } of the last succeeded or skipped run.
    def last_ok_runs
      Ops::HealthRun.where(status: %w[succeeded skipped]).group(:season_id, :group_key).maximum(:finished_at)
    end

    def daily_mark
      @daily_mark ||= Time.zone.parse("#{@now.to_date.iso8601} #{DAILY_AT}")
    end

    def enqueue_daily
      return [] if @now < daily_mark

      (@scope.current + @scope.upcoming).flat_map do |entry|
        entry.groups.filter_map do |group|
          last = @last_ok[[entry.season_id, group]]
          next if last && last >= daily_mark

          enqueue(entry.season_id, group, trigger: last.nil? || last < @now - 2.days ? 'catch_up' : 'scheduled')
        end
      end
    end

    # Enqueues the most overdue closed season (never run first, newest season first). Returns its id or nil.
    def enqueue_closed
      candidates = @scope.closed.reject(&:no_data?)
      return if Ops::HealthRun.pending.exists?(season_id: candidates.map(&:season_id))

      entry = candidates.select { |candidate| closed_due?(candidate) }.min_by { |candidate| closed_order(candidate) }
      return unless entry

      trigger = closed_trigger(oldest_run(entry))
      entry.groups.each { |group| enqueue(entry.season_id, group, trigger:, skip_unchanged: true) }
      entry.season_id
    end

    # Sort key: never run first, then the oldest last run, then the newest season.
    def closed_order(entry)
      oldest = oldest_run(entry)
      [oldest ? 1 : 0, oldest.to_f, -entry.begin_date.jd]
    end

    def closed_trigger(oldest)
      oldest.nil? || oldest < @now - (CLOSED_INTERVAL * 2) ? 'catch_up' : 'scheduled'
    end

    # Oldest "last ok run" time among the groups of the season (nil when a group never ran).
    def oldest_run(entry)
      times = entry.groups.map { |group| @last_ok[[entry.season_id, group]] }
      times.include?(nil) ? nil : times.min
    end

    def closed_due?(entry)
      oldest = oldest_run(entry)
      oldest.nil? || oldest < @now - CLOSED_INTERVAL
    end

    def enqueue(season_id, group, trigger:, skip_unchanged: false)
      Health::SeasonRunJob.enqueue(season_id:, group:, trigger:, skip_unchanged:, priority: Health::SeasonRunJob::PRIORITY_SWEEP)
    rescue StandardError => e
      Rails.logger.error("[Health::SweepJob] enqueue failed for season #{season_id} #{group}: #{e.class}: #{e.message}")
      nil
    end
  end
end
