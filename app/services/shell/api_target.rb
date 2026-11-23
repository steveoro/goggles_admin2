# frozen_string_literal: true

module Shell
  #
  # = Shell::APITarget
  #
  # Value object describing the API server the app currently talks to, for the top bar:
  # - url: the configured API base URL (local DB settings; no remote call);
  # - label: the operator's label for that URL (Ops::Setting 'api_target.labels', a JSON Hash URL => label);
  # - guess: :production when the URL ends with port 447, :unknown otherwise. It's a port-based guess,
  #   always shown as "unverified" (phase 08 replaces it with the environment reported by the API).
  #   It never says "staging";
  # - reachability: :reachable / :unreachable / :unknown, plus taken_at, from the 'api.status:<url>' snapshot
  #   (see SystemStatus::APISnapshot); always :unreachable in an API-offline session (with the session time).
  #
  # With the ops DB missing: label nil and reachability :unknown. Never raises, never calls the API.
  #
  class APITarget
    LABELS_KEY = 'api_target.labels'
    PRODUCTION_PORT_REGEXP = /:447\z/
    LABEL_MAX_LENGTH = 60

    attr_reader :url

    # Returns the APITarget for the configured API URL.
    # == Params:
    # - offline_info: the API-offline session details Hash ('url', 'reason', 'at'), or nil for a regular session.
    def self.current(offline_info: nil)
      new(url: configured_url, offline_info:)
    end

    # Configured API base URL (local DB read); blank when the settings can't be read.
    def self.configured_url
      APIProxy.configured_base_url.to_s.strip.delete_suffix('/')
    rescue StandardError => e
      Rails.logger.warn("[Shell::APITarget] cannot read the API URL: #{e.class}: #{e.message}")
      ''
    end

    # All the stored labels (URL => label); empty Hash when none or the ops DB is not available.
    def self.labels
      Ops.safely({}) do
        next {} unless Ops.available?

        stored = Ops::Setting.fetch(LABELS_KEY, {})
        stored.is_a?(Hash) ? stored : {}
      end
    end

    # Stores (or, when blank, removes) the label for +url+. Returns true on success, false otherwise
    # (e.g. ops DB not available).
    def self.store_label!(url, label)
      key = url.to_s.strip.delete_suffix('/')
      return false if key.blank?

      Ops.safely(false) do
        next false unless Ops.available?

        updated = labels.dup
        clean_label = label.to_s.squish.first(LABEL_MAX_LENGTH)
        clean_label.present? ? updated[key] = clean_label : updated.delete(key)
        Ops::Setting.store!(LABELS_KEY, updated)
        true
      end
    end

    def initialize(url:, offline_info: nil)
      @url = url.to_s.strip.delete_suffix('/')
      @offline_info = offline_info.presence
    end

    def offline?
      !@offline_info.nil?
    end

    # Operator label for the URL, or nil.
    def label
      return @label if defined?(@label)

      @label = self.class.labels[url].presence
    end

    # :production for a URL ending with port 447, :unknown otherwise (never :staging).
    def guess
      PRODUCTION_PORT_REGEXP.match?(url) ? :production : :unknown
    end

    # :reachable, :unreachable or :unknown.
    def reachability
      return :unreachable if offline?
      return :unknown if snapshot.nil?

      snapshot.payload.is_a?(Hash) && snapshot.payload['reachable'] ? :reachable : :unreachable
    end

    # Time of the reachability info (the API-offline sign-in time for offline sessions), or nil.
    def taken_at
      return parse_time(@offline_info['at']) if offline?

      snapshot&.taken_at
    end

    # API version reported by the last successful check, or nil.
    def version
      return if offline? || snapshot.nil? || !snapshot.payload.is_a?(Hash)

      snapshot.payload['version'].presence
    end

    # Error detail of the last failed check (or the API-offline reason), or nil.
    def error
      return @offline_info['reason'].presence if offline?
      return if snapshot.nil? || !snapshot.payload.is_a?(Hash)

      snapshot.payload['error'].presence
    end

    private

    def snapshot
      return @snapshot if defined?(@snapshot)

      @snapshot = url.present? ? SystemStatus::APISnapshot.read(url) : nil
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
