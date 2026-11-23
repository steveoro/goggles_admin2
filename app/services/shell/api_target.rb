# frozen_string_literal: true

module Shell
  #
  # = Shell::APITarget
  #
  # Value object describing the API server the app currently talks to, for the top bar:
  # - url: the configured API base URL (local DB settings; no remote call);
  # - label: the operator's label for that URL (Ops::Setting 'api_target.labels', a JSON Hash URL => label);
  # - environment: the environment reported by the API itself in its last 'status' answer (APICapabilities,
  #   phase 08), e.g. 'production' or 'development': #verified? is then true. With an older API (or before the
  #   first check) it falls back to the port-based #guess, shown as "unverified";
  # - guess: :production when the URL ends with port 447, :unknown otherwise (never "staging");
  # - label_mismatch?: the operator label names another environment than the one the API reports
  #   (e.g. label "Production" on a 'development' API);
  # - reachability: :reachable / :unreachable / :unknown, plus taken_at, from the 'api.status:<url>' snapshot
  #   (see SystemStatus::APISnapshot); always :unreachable in an API-offline session (with the session time).
  #
  # With the ops DB missing: label nil and reachability :unknown. Never raises, never calls the API.
  #
  class APITarget
    LABELS_KEY = 'api_target.labels'
    PRODUCTION_PORT_REGEXP = /:447\z/
    LABEL_MAX_LENGTH = 60
    # Environment named by an operator label (first match wins), for #label_mismatch?
    LABEL_ENVIRONMENTS = {
      'production' => /\b(prod|production|produzione)\b/i,
      'development' => /\b(dev|devel|development|sviluppo|local|locale)\b/i,
      'test' => /\btest\b/i
    }.freeze

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

    # The environment reported by the API ('production', 'development', ...), or nil (older API, never checked,
    # API-offline session).
    def api_environment
      return if offline? || url.blank?

      capabilities.environment
    end

    # True when the environment comes from the API itself.
    def verified?
      api_environment.present?
    end

    # The environment to show: the API's own answer, else the port guess ('production' or 'unknown').
    def environment
      api_environment || guess.to_s
    end

    # The API capabilities (APICapabilities, from the same stored answer).
    def capabilities
      @capabilities ||= APICapabilities.new(base_url: url, snapshot:)
    end

    # Environment named by the operator label (see LABEL_ENVIRONMENTS), or nil.
    def label_environment
      return if label.blank?

      LABEL_ENVIRONMENTS.find { |_env, regexp| regexp.match?(label) }&.first
    end

    # True when the label names an environment other than the one reported by the API.
    def label_mismatch?
      verified? && label_environment.present? && label_environment != api_environment
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
