# frozen_string_literal: true

module Health
  #
  # = Health::Runner
  #
  # Runs one check group for one season and records it as an Ops::HealthRun (ops DB):
  # 1. the run goes 'running' (a queued run created by Health::SeasonRunJob.enqueue, or a new row);
  # 2. with <tt>skip_unchanged: true</tt> (sweeps of closed seasons) a heavy group whose data stamp
  #    (Health::Stamp) and check versions equal those of its last succeeded run is recorded 'skipped': no check runs;
  # 3. the group class (Health::Registry.group_class) returns its findings, then Health::FindingSync stores them;
  # 4. the run goes 'succeeded' (counts, duration_ms, db_epoch, stamp, check versions) or, on any error, 'failed'
  #    with the error message: a failed run resolves nothing;
  # 5. only the last Ops::HealthRun::KEPT_PER_GROUP runs per (season, group) are kept, and every open page is
  #    pinged ('health-ping', see Health::Notifier).
  #
  # Never writes to the primary (MySQL) DB. Does nothing (returns nil) when the ops DB is not available.
  #
  class Runner
    attr_reader :season, :group_key, :trigger

    # == Params:
    # - season: GogglesDb::Season; group: one of Ops::HealthRun::GROUPS; trigger: one of Ops::HealthRun::TRIGGERS;
    # - run: an existing queued Ops::HealthRun to use (optional); job_id: the Active Job id (optional);
    # - skip_unchanged: skip a stamp-skippable group whose data didn't change since its last succeeded run;
    # - scope: Health::SeasonScope (default: a new one); data_dir: crawler data folder; now: reference time.
    def initialize(season:, group:, trigger:, run: nil, job_id: nil, skip_unchanged: false, scope: nil, data_dir: nil, now: nil) # rubocop:disable Metrics/ParameterLists
      @season = season
      @group_key = group.to_s
      @trigger = trigger.to_s
      @run = run
      @job_id = job_id
      @skip_unchanged = skip_unchanged
      @scope = scope || SeasonScope.new
      @data_dir = data_dir || SeasonBoard::DiskIndex.default_data_dir
      @now = now
    end

    # Returns the finished Ops::HealthRun (nil when the ops DB is not available).
    def call
      return unless Ops.available?

      run = start_run
      @started = monotonic_now
      begin
        perform(run)
      rescue StandardError => e
        Rails.logger.error("[Health::Runner] season #{season.id} #{group_key}: #{e.class}: #{e.message}")
        finish(run, status: 'failed', error_message: "#{e.class}: #{e.message}".truncate(2000))
      end
      Ops.safely { Ops::HealthRun.prune!(season_id: season.id, group_key:) }
      Health::Notifier.ping
      run
    end

    private

    def now = @now || Time.current

    def perform(run)
      stamp = Stamp.new(season_id: season.id, data_dir: @data_dir)
      versions = Registry.versions_for(group_key)
      return finish(run, status: 'skipped', stamp: stamp.digest, check_versions: versions) if unchanged?(stamp, versions)

      findings = check_class.new(season:, entry:, today: now.to_date, data_dir: @data_dir).call
      sync = FindingSync.new(run:, findings:, now:).call
      finish(run, status: 'succeeded', stamp: stamp.digest, check_versions: versions, counts: sync.counts,
                  findings_count: sync.findings_count, new_count: sync.new_count, resolved_count: sync.resolved_count)
    end

    def start_run
      run = @run if @run&.status == 'queued'
      attributes = { status: 'running', started_at: now, job_id: @job_id || @run&.job_id, db_epoch: Ops::Setting.db_epoch }
      if run
        run.update!(attributes)
        run
      else
        Ops::HealthRun.create!(season_id: season.id, group_key:, trigger:, **attributes)
      end
    end

    def finish(run, status:, **attributes)
      run.update!(status:, finished_at: Time.current, duration_ms: ((monotonic_now - @started) * 1000).round, **attributes)
      run
    end

    def unchanged?(stamp, versions)
      return false unless @skip_unchanged && Registry.stamp_skippable?(group_key)

      last = Ops::HealthRun.last_succeeded(season_id: season.id, group_key:)
      last.present? && last.stamp == stamp.digest && last.check_versions.to_h == versions
    end

    def check_class = Registry.group_class(group_key)

    def entry
      @scope.entry(season.id) || raise(ArgumentError, "season #{season.id} not found")
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
