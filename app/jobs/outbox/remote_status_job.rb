# frozen_string_literal: true

module Outbox
  #
  # = Outbox::RemoteStatusJob
  #
  # Read-only follow-up of the pushed scripts ('sent', "sent, not verified"): one GET 'import_queue/:id' per
  # script pushed to the configured API at least Ops::SqlScript::EXECUTED_DELAY ago, with the stored admin JWT
  # (Ops::BackgroundCredentials). A null body (the remote import queue row is gone: the Main app processed it)
  # turns the script into 'executed_unreported' ("executed, outcome not reported"; phase 08 reads the outcome).
  #
  # - Returns at once when no script is 'sent' (no call at all).
  # - Expired or missing JWT: no call, no state change, snapshot status 'no_credentials' ("sign in to refresh").
  # - Unreachable server: stops at the first failure (snapshot status 'unreachable').
  # - Scripts pushed to another API URL are skipped (the JWT is for the configured one).
  #
  # Recurring every 2 minutes ('outbox_remote_status' in config/recurring.yml) and enqueued by the Outbox page
  # (#enqueue_if_due). Never pushes, posts or changes anything remotely.
  #
  # == Snapshot 'outbox.remote_status' (String keys)
  #   { 'status' => 'ok' | 'no_credentials' | 'unreachable' | 'idle', 'url' =>, 'checked' => n, 'executed' => n, 'error' => }
  #
  class RemoteStatusJob < ApplicationJob
    queue_as :default

    limits_concurrency key: 'outbox_remote_status', to: 1, duration: 5.minutes, on_conflict: :discard

    SNAPSHOT_KEY = 'outbox.remote_status'
    # The Outbox page enqueues a check at most this often.
    DUE_AFTER = 2.minutes
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_PER_RUN = 50

    class << self
      # The last Ops::Snapshot, or nil. Never raises.
      def read
        Ops.safely { Ops::Snapshot.read(SNAPSHOT_KEY) if Ops.available? }
      end

      # Enqueues a check when some script is 'sent' and the last check is older than DUE_AFTER. Never raises.
      def enqueue_if_due(now: Time.current)
        Ops.safely(false) do
          next false unless Ops.available? && Ops::SqlScript.sent.exists?

          last = read&.taken_at
          next false if last && last > now - DUE_AFTER

          perform_later
          true
        end
      end
    end

    # Returns the snapshot payload (or nil when the ops DB is not available).
    def perform(now: Time.current)
      return unless Ops.available?

      base_url = APIProxy.configured_base_url.to_s.delete_suffix('/')
      scripts = Ops::SqlScript.sent.where(target_api_url: [base_url, "#{base_url}/"])
                              .where(Ops::SqlScript.arel_table[:pushed_at].lteq(now - Ops::SqlScript::EXECUTED_DELAY))
                              .where.not(remote_iq_id: nil).ordered.limit(MAX_PER_RUN).to_a
      return store('status' => 'idle', 'url' => base_url) if scripts.empty?

      jwt = Ops::BackgroundCredentials.jwt
      return store('status' => 'no_credentials', 'url' => base_url) if jwt.blank?

      check(scripts, base_url, jwt, now)
    end

    private

    def check(scripts, base_url, jwt, now) # rubocop:disable Metrics/AbcSize
      counts = { 'checked' => 0, 'executed' => 0 }
      scripts.each do |script|
        result = APIProxy.call(method: :get, url: "import_queue/#{script.remote_iq_id}", jwt:, base_url:,
                               open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT)
        return store(counts.merge('status' => 'unreachable', 'url' => base_url, 'error' => result.error_detail.to_s.truncate(300))) if result.unreachable?
        return store(counts.merge('status' => 'no_credentials', 'url' => base_url)) if result.code.to_i == 401

        counts['checked'] += 1
        next script.update!(remote_checked_at: now) unless remote_row_gone?(result)

        script.mark_executed_unreported!(now:)
        counts['executed'] += 1
        Ops.record_event!(kind: 'outbox.executed_unreported', level: 'success', actor: 'job', season_id: script.season_id,
                          subject_type: 'sql_script', subject_key: script.id,
                          data: { 'file' => script.filename, 'import_queue_id' => script.remote_iq_id })
      end
      Outbox::Notifier.ping if counts['executed'].positive?
      store(counts.merge('status' => 'ok', 'url' => base_url))
    end

    # A successful answer with a null (or empty) body: the row was deleted after its processing.
    def remote_row_gone?(result)
      (200..299).cover?(result.code.to_i) && result.json.blank?
    end

    def store(payload)
      Ops.safely { Ops::Snapshot.write!(SNAPSHOT_KEY, payload, source: self.class.name) }
      payload
    end
  end
end
