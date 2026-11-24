# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::ActivityFeedComponent
  #
  # The latest Ops::Event rows (commits, pushes, purges, Season board jobs, FIN watcher), newest first, with a link
  # to the full /activity page. Shows a notice instead when the ops DB is not available.
  #
  class ActivityFeedComponent < ViewComponent::Base
    # Event level => [icon, text colour class]
    LEVEL_STYLES = {
      'info' => %w[fa-circle-info text-info-emphasis], 'success' => %w[fa-circle-check text-success],
      'warning' => %w[fa-triangle-exclamation text-warning-emphasis], 'error' => %w[fa-circle-xmark text-danger]
    }.freeze

    # == Params:
    # - events: Array of Ops::Event (newest first); ops_available: false when the ops DB is not ready;
    # - now: reference time.
    def initialize(events:, ops_available:, now: Time.current)
      super()
      @events = events
      @ops_available = ops_available
      @now = now
    end

    # Icon & colour of an event level.
    def self.level_style(level)
      LEVEL_STYLES.fetch(level.to_s, LEVEL_STYLES['info'])
    end

    # Short label of the event subject (file base name for paths).
    def self.subject_label(event)
      key = event.subject_key.to_s
      key.include?('/') ? File.basename(key) : key
    end

    protected

    # 'HH:MM' for today, else the short date & time.
    def time_label(time)
      local = time.localtime
      local.to_date == @now.localtime.to_date ? local.strftime('%H:%M') : l(local, format: :short)
    end
  end
end
