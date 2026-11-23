# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::InProgressComponent
  #
  # The dashboard "In progress" zone: the Season board crawls & extractions queued or running
  # (SeasonBoard::ActivityLog#active), the Solid Queue jobs running and the queued ones per queue
  # (Dashboard::QueueActivity), and the next scheduled runs. Carries the busy marker read by the live-frames
  # Stimulus controller (reload every 20 s while something runs).
  #
  class InProgressComponent < ViewComponent::Base
    # == Params:
    # - activities: Array of SeasonBoard::ActivityLog::Entry (queued/running, running first);
    # - names: Hash of FIN event id => meeting name;
    # - queue: a Dashboard::QueueActivity; next_runs: Array of [label_key, Time] (see SeasonBoard::ActivityStripComponent);
    # - now: reference time.
    def initialize(activities:, names:, queue:, next_runs:, now: Time.current)
      super()
      @activities = activities
      @names = names
      @queue = queue
      @next_runs = next_runs
      @now = now
    end

    # True when anything is queued or running.
    def busy?
      @activities.any? || @queue.busy?
    end

    protected

    def activity_rows
      @activities.map do |entry|
        {
          status: entry.running? ? :running : :queued, kind: t("season_board.strip.kinds.#{entry.kind}"),
          name: SeasonBoard::ActivityStripComponent.entry_name(entry, @names),
          origin: t("season_board.strip.origin.#{entry.origin || :manual}"), time: entry.started_at || entry.queued_at
        }
      end
    end

    def queued_text
      queued = @queue.queued.select { |_name, count| count.positive? }
      return if queued.empty?

      t('dashboard.in_progress.jobs_queued', queues: queued.map { |name, count| "#{name} #{count}" }.join(', '))
    end

    def hour(time)
      time ? l(time.localtime, format: :short) : '?'
    end

    def next_run_text(label_key, time)
      t("season_board.strip.#{label_key}", time: l(time.localtime, format: :short))
    end
  end
end
