# frozen_string_literal: true

module DataFix
  #
  # = DataFix::Automation
  #
  # The kill switches of the pipeline automation (phase 10), read by SeasonBoard::PipelinePlanner before every enqueue,
  # by the crawl planners and by the jobs at start when they run for an automatic request:
  #
  # - :enabled      ('automation.enabled', master): automatic crawls, extractions and prepares;
  # - :auto_extract ('automation.auto_extract'): unattended manifest extraction (LLM engine);
  # - :auto_prepare ('automation.auto_prepare'): unattended Data-Fix prepares (phases 1-5, never a commit).
  #
  # Every switch defaults to on (Ops::Setting keys, values true/false). The environment variable ADMIN2_AUTOMATION=0
  # (also 'false' / 'off') forces all of them off, without touching the stored values. Without the ops DB (not
  # configured / not migrated) the master switch keeps its default (the automatic crawls work as before), while
  # :auto_extract and :auto_prepare are off: their attempt counts, leases and run rows live in the ops DB.
  #
  # Fail closed: a switch that cannot be READ (e.g. a locked ops SQLite DB, any error after one retry) counts as OFF,
  # so a stored "off" can never be read as "on" by automatic work. The operator buttons do not read the switches.
  #
  # == Usage
  #   DataFix::Automation.enabled?                 # => master switch
  #   DataFix::Automation.enabled?(:auto_prepare)  # => master AND auto_prepare
  #   DataFix::Automation.store!(:auto_extract, false, user_id: current_user.id)
  #
  module Automation
    SWITCHES = %i[enabled auto_extract auto_prepare].freeze
    KEYS = SWITCHES.index_with { |switch| "automation.#{switch}" }.freeze
    ENV_KEY = 'ADMIN2_AUTOMATION'
    ENV_OFF_VALUES = %w[0 false off no].freeze
    EVENT_KIND = 'automation.switched'

    # One switch as shown by the UI: +stored+ is the stored value, +effective+ what the planner obeys.
    Switch = Data.define(:key, :stored, :effective) do
      # 'on', 'paused' (stored on, but off because of the master switch, the env override or the ops DB) or 'off'.
      def state
        if effective then 'on'
        elsif stored then 'paused'
        else 'off'
        end
      end
    end

    module_function

    # True when the switch is effectively on: the env override is not set, the master switch is on and (for a
    # sub-switch) the sub-switch is on too.
    def enabled?(switch = :enabled)
      switch = check!(switch)
      return false if env_off?
      return false unless stored(:enabled)
      return true if switch == :enabled

      Ops.available? && stored(switch)
    end

    # Stored value of the switch (default true); without the ops DB the master switch is true, the others false.
    # An unreadable switch is false (fail closed, see the module notes).
    def stored(switch)
      switch = check!(switch)
      return switch == :enabled unless Ops.available?

      read_setting(KEYS.fetch(switch)) != false
    rescue StandardError => e
      Rails.logger.warn("[DataFix::Automation] switch #{switch} unreadable, counted as off: #{e.class}: #{e.message}")
      false
    end

    # The stored value (true when never stored); raises when the ops DB cannot be read (one retry when busy).
    def read_setting(key)
      Ops::Setting.fetch(key, true)
    rescue ActiveRecord::StatementTimeout
      Ops::Setting.fetch(key, true)
    end

    # True when ADMIN2_AUTOMATION forces every switch off.
    def env_off?
      ENV_OFF_VALUES.include?(ENV.fetch(ENV_KEY, '').to_s.strip.downcase)
    end

    # The three switches (Array of Switch), for the dashboard and the Season board header.
    def switches
      SWITCHES.map { |switch| Switch.new(key: switch, stored: stored(switch), effective: enabled?(switch)) }
    end

    # True when anything is off (master off, a sub-switch off, the env override, or the ops DB missing).
    def paused?
      SWITCHES.any? { |switch| !enabled?(switch) }
    end

    # Stores the switch (true/false) and records an 'automation.switched' event. Returns the stored value, or nil
    # without the ops DB.
    def store!(switch, value, user_id: nil)
      switch = check!(switch)
      value = ActiveModel::Type::Boolean.new.cast(value) == true
      Ops.safely do
        next unless Ops.available?

        Ops::Setting.store!(KEYS.fetch(switch), value)
        Ops.record_event!(kind: EVENT_KIND, level: value ? 'info' : 'warning', actor: 'operator',
                          subject_type: 'setting', subject_key: KEYS.fetch(switch),
                          data: { 'switch' => switch.to_s, 'value' => value, 'user_id' => user_id }, link_path: '/#dashboard-system')
        value
      end
    end

    def check!(switch)
      sym = switch.to_s.to_sym
      raise ArgumentError, "unknown automation switch #{switch.inspect}" unless SWITCHES.include?(sym)

      sym
    end
  end
end
