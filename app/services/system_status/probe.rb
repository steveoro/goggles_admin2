# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::Probe
  #
  # Base class of the status probes listed by SystemStatus::Registry.
  #
  # Each probe has a +key+, a +label_key+ (i18n) and a +mode+:
  # - :inline   => cheap local read, evaluated while rendering the status frame;
  # - :snapshot => anything touching the network: SystemStatus::RefreshJob runs #refresh! (which writes an
  #                ops snapshot), while #call only reads that snapshot.
  #
  # #call always returns a SystemStatus::Result and never raises: any exception becomes an :unknown result.
  #
  # == Subclasses implement:
  # - #evaluate => SystemStatus::Result (use #result to build it);
  # - snapshot probes also: #snapshot_key and #refresh! (network call + snapshot write).
  #
  class Probe
    MODES = %i[inline snapshot].freeze

    # Snapshots older than this are reported as stale (:unknown):
    STALE_AFTER = 15.minutes

    class << self
      # Probe key (Symbol), e.g. :api. Defaults to the class name without the 'Probe' suffix.
      def key
        name.demodulize.delete_suffix('Probe').underscore.to_sym
      end

      def label_key
        "shell.status.#{key}.label"
      end

      def mode
        :inline
      end

      def snapshot?
        mode == :snapshot
      end
    end

    attr_reader :offline, :api_url, :now

    # == Params:
    # - offline: true for an API-offline session;
    # - api_url: the configured API base URL (default: read from the local settings);
    # - now: reference time (default: Time.current).
    def initialize(offline: false, api_url: nil, now: nil)
      @offline = offline
      @api_url = api_url
      @now = now || Time.current
    end

    delegate :key, :label_key, :mode, :snapshot?, to: :class

    # Returns the SystemStatus::Result for this probe; never raises.
    def call
      evaluate
    rescue StandardError => e
      Rails.logger.warn("[SystemStatus] #{self.class.name} failed: #{e.class}: #{e.message}")
      result(:unknown, detail: I18n.t('shell.status.failed', error: e.class.name))
    end

    # Ops snapshot key written by #refresh! (snapshot probes only).
    def snapshot_key
      "system_status.#{key}"
    end

    # The stored Ops::Snapshot for this probe, or nil (inline probe, missing snapshot or ops DB not available).
    def snapshot
      return unless snapshot?
      return @snapshot if defined?(@snapshot)

      @snapshot = Ops.safely { Ops::Snapshot.read(snapshot_key) if Ops.available? }
    end

    # True when the snapshot is missing or older than +max_age+ (always false for inline probes).
    def refresh_due?(max_age)
      return false unless snapshot?

      snapshot.nil? || snapshot.taken_at < now - max_age
    end

    # Snapshot probes: performs the (network) check and writes the snapshot. Never called while rendering.
    def refresh!
      raise NotImplementedError, "#{self.class.name}#refresh!" if snapshot?
    end

    protected

    def evaluate
      raise NotImplementedError, "#{self.class.name}#evaluate"
    end

    def label
      I18n.t(label_key)
    end

    def result(level, detail: nil, checked_at: nil, action: nil)
      Result.new(key:, label:, level:, detail:, checked_at:, action:)
    end

    # Translated detail for this probe ('shell.status.<key>.<name>').
    def detail_text(name, **interpolations)
      I18n.t("shell.status.#{key}.#{name}", **interpolations)
    end

    # True when +time+ is older than STALE_AFTER.
    def stale?(time)
      time.nil? || time < now - STALE_AFTER
    end

    # Short localized time (system time zone: the app runs on the operator's machine, with UTC as its zone).
    def format_time(time)
      time ? I18n.l(time.localtime, format: :short) : '-'
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
  end
end
