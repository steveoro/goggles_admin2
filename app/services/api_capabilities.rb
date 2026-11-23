# frozen_string_literal: true

#
# = APICapabilities
#
# What an API server says about itself, from the last 'status' answer stored in the ops snapshot
# 'api.status:<base_url>' (SystemStatus::APISnapshot; refreshed by SystemStatus::RefreshJob every 5 minutes and by
# the Outbox push confirmation). Never calls the network, never raises.
#
# The API (goggles_api 0.10.81 and later) answers <tt>GET status</tt> with
#   { "msg": "OK", "version": "...", "environment": "production",
#     "capabilities": ["iq_batch_outcome", "iq_batch_filters", "db_fingerprint"] }
# An older API reports neither key: #environment is nil and #supports? is always false, so every caller keeps
# its pre-08 behaviour (feature detection).
#
# == Capabilities
# - iq_batch_outcome: the import queue rows of the SQL batches report 'applied' / 'failed' (and are kept 14 days);
# - iq_batch_filters: 'import_queues?batch_sql=true&done=false' filter for real (and expose data_file_checksum);
# - db_fingerprint:   'tools/db_fingerprint' (Drift::Fingerprint.remote).
#
# == Usage
#   caps = APICapabilities.for(APIProxy.configured_base_url)
#   caps.environment               # => 'production' | 'development' | ... | nil (not reported)
#   caps.supports?(:db_fingerprint) # => true / false
#
class APICapabilities
  KNOWN = %w[iq_batch_outcome iq_batch_filters db_fingerprint].freeze

  attr_reader :base_url

  # Capabilities of +base_url+ (default: the configured API).
  def self.for(base_url = nil)
    new(base_url: base_url.presence || APIProxy.configured_base_url)
  end

  def initialize(base_url:, snapshot: :read)
    @base_url = base_url.to_s.strip.delete_suffix('/')
    @snapshot = snapshot unless snapshot == :read
  end

  # The stored Ops::Snapshot ('api.status:<base_url>'), or nil.
  def snapshot
    return @snapshot if defined?(@snapshot)

    @snapshot = base_url.present? ? SystemStatus::APISnapshot.read(base_url) : nil
  end

  # The environment reported by the API ('production', 'development', ...), or nil when not reported.
  def environment
    payload['environment'].to_s.strip.downcase.presence
  end

  # Capability names reported by the API (Strings; empty when not reported).
  def capabilities
    Array(payload['capabilities']).map(&:to_s)
  end

  # True when the API reported +name+ among its capabilities.
  def supports?(name)
    capabilities.include?(name.to_s)
  end

  # True when the last answer reported the capabilities at all (an API 0.10.81 or later).
  def reported?
    payload.key?('capabilities') && !payload['capabilities'].nil?
  end

  # Time of the stored answer, or nil.
  def checked_at
    snapshot&.taken_at
  end

  def version
    payload['version'].presence
  end

  private

  def payload
    data = snapshot&.payload
    data.is_a?(Hash) ? data : {}
  end
end
