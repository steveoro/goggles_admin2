# frozen_string_literal: true

require 'fugit'

module SeasonBoard
  #
  # = SeasonBoard::ActivityStripComponent
  #
  # Compact strip showing the background crawl/extraction activity (from SeasonBoard::ActivityLog):
  # what is running now (with the meeting name, when resolvable, and the start time), how many
  # activities are queued and the next scheduled runs (next watcher check & next daily re-check),
  # computed from the schedules in config/recurring.yml.
  #
  # Shown on the Season board and on the Pull pages, so that a manual crawl isn't started on top of
  # an automatic one.
  #
  class ActivityStripComponent < ViewComponent::Base
    RECURRING_PATH = Rails.root.join('config/recurring.yml')

    # Recurring task keys (config/recurring.yml) and the label key of their "next run" line:
    SCHEDULED_TASKS = {
      'federnuoto_watch' => :next_check,
      'season_board_recheck' => :next_recheck
    }.freeze

    # == Params:
    # - activities: Array of SeasonBoard::ActivityLog::Entry (queued/running); default: the current active ones;
    # - names: Hash of FIN event id => meeting name; default: names found in the watcher snapshot;
    # - recurring_path: path of the recurring tasks YAML file;
    # - now: reference time.
    def initialize(activities: nil, names: nil, recurring_path: RECURRING_PATH, now: Time.current)
      super()
      @activities = activities || safe_active_activities
      @names = names || snapshot_names
      @recurring_path = recurring_path
      @now = now
    end

    def self.entry_name(entry, names = nil)
      names ||= {}
      names[entry.fin_event_id.to_s].presence || "FIN ##{entry.fin_event_id}"
    end

    # Returns the confirm text for the "CRAWLER run" buttons: the existing one when nothing
    # automatic is running or queued; otherwise the existing text followed by the overlap warning.
    def self.crawler_confirm_text(default_text)
      strip = new
      warning = strip.send(:overlap_warning)
      warning ? "#{warning}\n\n#{default_text}" : default_text
    end

    protected

    def running
      @activities.select(&:running?)
    end

    def queued
      @activities.select(&:queued?)
    end

    def entry_label(entry)
      self.class.entry_name(entry, @names)
    end

    def kind_label(entry)
      I18n.t("season_board.strip.kinds.#{entry.kind}")
    end

    def origin_label(entry)
      I18n.t("season_board.strip.origin.#{entry.origin || :manual}")
    end

    def time_label(time)
      time ? time.in_time_zone.strftime('%H:%M') : '?'
    end

    # Returns the Array of [label_key, Time] for the scheduled tasks found & parsable.
    def next_runs
      SCHEDULED_TASKS.filter_map do |task_key, label_key|
        time = next_run_for(task_key)
        [label_key, time] if time
      end
    end

    def format_next_run(time)
      I18n.l(time.in_time_zone, format: :short)
    end

    private

    # Warning text about the running/queued automatic crawls, or nil when there are none.
    def overlap_warning
      running_crawls = running.select { |entry| entry.kind == :crawl }
      return I18n.t('season_board.crawler_confirm.running', names: running_crawls.map { |entry| entry_label(entry) }.join(', ')) if running_crawls.any?

      queued_auto = queued.count { |entry| entry.kind == :crawl && entry.origin == :auto }
      I18n.t('season_board.crawler_confirm.queued', count: queued_auto) if queued_auto.positive?
    end

    def safe_active_activities
      SeasonBoard::ActivityLog.new.active
    rescue StandardError
      []
    end

    def snapshot_names
      Array(FedernuotoWatch::StateStore.new.read['rows']).each_with_object({}) do |row, memo|
        fin_id = FINEventId.parse(row['url'])
        memo[fin_id] = row['name'] if fin_id && row['name'].present?
      end
    rescue StandardError
      {}
    end

    # Next run time of the recurring task (Time), or nil when the key is missing or the schedule unparsable.
    def next_run_for(task_key)
      schedule = recurring_tasks.dig(task_key, 'schedule')
      return if schedule.blank?

      parsed = Fugit.parse(schedule.to_s)
      return unless parsed.respond_to?(:next_time)

      parsed.next_time(@now)&.to_t
    rescue StandardError
      nil
    end

    def recurring_tasks
      @recurring_tasks ||= begin
        raw = YAML.safe_load(ERB.new(File.read(@recurring_path)).result, aliases: true)
        raw.is_a?(Hash) ? (raw[Rails.env] || raw) : {}
      rescue StandardError
        {}
      end
    end
  end
end
