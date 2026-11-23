# frozen_string_literal: true

#
# = DriftCheckJob
#
# DB sync check (phase 08): compares the local DB with the configured API's 'tools/db_fingerprint' (count, max id and
# max updated_at of the whitelisted tables; read-only queries on both sides, one GET with the background JWT and
# short timeouts) and stores the verdict as an Ops::DbFingerprint (Drift::Check). Never commits, pushes or applies
# anything. Against an API without the 'db_fingerprint' capability the stored verdict is 'unknown' (no call).
#
# Enqueued by:
# - the recurring 'drift_check' task, every 30 minutes (config/recurring.yml; trigger 'schedule');
# - "Check now" on /db_sync (trigger 'manual');
# - Outbox::Pusher at the end of each push run (trigger 'post_push');
# - SystemStatus::RefreshJob when the last job check is missing or old (see SystemStatus::DbSyncProbe).
# Against an API that can't be compared (no capability, no background JWT) the local side is read in light mode
# only (Drift::Check).
# Does nothing when the ops DB is not available.
#
class DriftCheckJob < ApplicationJob
  queue_as :default

  # One check at a time; duplicates enqueued meanwhile are dropped:
  limits_concurrency key: 'drift_check', to: 1, duration: 5.minutes, on_conflict: :discard

  # == Params:
  # - trigger: 'schedule' (default), 'manual' or 'post_push'; mode: 'full' (default) or 'light';
  # - base_url: API base URL (default: the configured one).
  # Returns the stored Ops::DbFingerprint (nil without the ops DB).
  def perform(trigger: 'schedule', mode: 'full', base_url: nil)
    fingerprint = Drift::Check.call(trigger:, mode:, base_url:)
    Drift::Notifier.ping if fingerprint
    fingerprint
  end
end
