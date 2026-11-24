# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::APISnapshot
  #
  # Reads & writes the 'api.status:<base_url>' ops snapshot: the one key holding the last known
  # reachability of an API server, plus (phase 08) the environment and the capabilities it reports
  # (read through APICapabilities).
  #
  # Written by SystemStatus::RefreshJob (APIProxy.ping), by SettingsController (where it already pings)
  # and by the sign-in outcome (Users::SessionsController); read by Shell::APITarget and SystemStatus::APIProbe.
  # Never raises: with the ops DB not available, reads return nil and writes do nothing.
  #
  # == Payload (String keys)
  # - 'url': API base URL; 'reachable': true when the server answered (any HTTP code);
  # - 'code': HTTP code (503 for an unreachable server); 'version', 'msg': from the 'status' endpoint, when known;
  # - 'error': error detail for unreachable servers and non-2xx answers (nil otherwise);
  # - 'environment': the environment reported by the API ('production', 'development', ...), nil when not reported;
  # - 'capabilities': Array of the capability names reported by the API, nil when not reported (an API older
  #   than 0.10.82: see APICapabilities).
  #
  class APISnapshot
    KEY_PREFIX = 'api.status:'

    class << self
      # Snapshot key for +base_url+ (trailing slash removed).
      def key_for(base_url)
        "#{KEY_PREFIX}#{normalize_url(base_url)}"
      end

      # Returns the Ops::Snapshot for +base_url+, or nil (missing snapshot or ops DB not available).
      def read(base_url)
        Ops.safely { Ops::Snapshot.read(key_for(base_url)) if Ops.available? }
      end

      # Writes the snapshot for +base_url+ from an APIProxy result (any object responding to #code;
      # #unreachable?, #json and #error_detail are used when available).
      # Returns the Ops::Snapshot or nil.
      def write!(base_url, result, source:)
        Ops.safely do
          next unless Ops.available?

          payload = payload_for(base_url, result)
          keep_known_details(payload, Ops::Snapshot.read(key_for(base_url)))
          Ops::Snapshot.write!(key_for(base_url), payload, source: source.to_s)
        end
      end

      # Payload Hash for an APIProxy result.
      def payload_for(base_url, result)
        code = result.code.to_i
        reachable = !(result.respond_to?(:unreachable?) && result.unreachable?)
        json = result.respond_to?(:json) ? result.json : nil
        json = {} unless json.is_a?(Hash)
        success = reachable && (200..299).cover?(code)
        {
          'url' => normalize_url(base_url), 'reachable' => reachable, 'code' => code,
          'version' => success ? json['version'] : nil, 'msg' => success ? json['msg'] : nil,
          'error' => success ? nil : error_detail_for(result)
        }.merge(reported_details(json, success))
      end

      private

      # 'environment' and 'capabilities' of a 'status' answer (nil when not reported: an API before 0.10.82).
      def reported_details(json, success)
        return { 'environment' => nil, 'capabilities' => nil } unless success

        capabilities = json['capabilities']
        { 'environment' => json['environment'].presence&.to_s,
          'capabilities' => capabilities.is_a?(Array) ? capabilities.map(&:to_s) : nil }
      end

      def normalize_url(base_url)
        base_url.to_s.strip.delete_suffix('/')
      end

      # A reachable answer without version info (e.g. the sign-in endpoint) keeps the version, environment and
      # capabilities of the previous check. (A 'status' answer always replaces them: an API rolled back to a version
      # without capabilities loses them at once.)
      def keep_known_details(payload, previous)
        return if payload['version'].present? || !payload['reachable']
        return unless previous&.payload.is_a?(Hash) && previous.payload['reachable']

        %w[version environment capabilities].each { |key| payload[key] = previous.payload[key] }
      end

      def error_detail_for(result)
        detail = result.respond_to?(:error_detail) ? result.error_detail : "Error #{result.code}"
        detail.to_s.truncate(300)
      end
    end
  end
end
