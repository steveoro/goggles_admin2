# frozen_string_literal: true

#
# = DriftCheckJob
#
# Drift v0: compares the latest-updated remote rows with the local DB (Drift::LatestUpdatesCheck, a read-only
# GET with the background JWT and short timeouts) and stores the verdict in the ops snapshot
# 'drift_v0:<api_base_url>'. Never commits, pushes or applies anything.
#
# Recurring every 30 minutes (config/recurring.yml, 'drift_check'); also enqueued by SystemStatus::RefreshJob
# when the snapshot is missing or old (see SystemStatus::DriftV0Probe). Does nothing when the ops DB is not
# available. Phase 08 adds the full fingerprint check to this job.
#
class DriftCheckJob < ApplicationJob
  queue_as :default

  # One check at a time; duplicates enqueued meanwhile are dropped:
  limits_concurrency key: 'drift_check', to: 1, duration: 5.minutes, on_conflict: :discard

  # == Params:
  # - base_url: API base URL (default: the configured one).
  # Returns the snapshot payload Hash (nil without the ops DB).
  def perform(base_url: nil)
    Drift::LatestUpdatesCheck.new(base_url:).call
  end
end
