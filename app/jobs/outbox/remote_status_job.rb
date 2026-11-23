# frozen_string_literal: true

require 'digest'

module Outbox
  #
  # = Outbox::RemoteStatusJob
  #
  # Read-only follow-up of the pushed scripts ('sent': queued on the server): one GET 'import_queue/:id' per
  # script pushed to the configured API, with the stored admin JWT (Ops::BackgroundCredentials).
  #
  # With an API reporting the batch outcomes (capability 'iq_batch_outcome', APICapabilities; see
  # Outbox::RemoteStatus for the encoding):
  # - applied => 'applied';
  # - failed  => 'failed' with the server error text (remote_error); the file moves back to results.new/<folder>/
  #              (the board row returns to "SQL to push"); the later scripts stay queued ("blocked by #NNNN"),
  #              because the server stops at the first failure until the operator retries, withdraws or discards it;
  # - queued / running => unchanged (check time noted);
  # - gone    => 'missing_remote' ("deleted on server": applied rows are kept 14 days on the server).
  # Without the capability (an older API) a vanished row turns the script into 'executed_unreported' after
  # Ops::SqlScript::EXECUTED_DELAY, as in phase 07.
  #
  # With capability 'iq_batch_filters' the 'in_doubt' scripts (a push interrupted between the POST and the move) are
  # looked up once per run in <tt>import_queues?batch_sql=true</tt> by file checksum
  # (<tt>data_file_checksum</tt> = base64 MD5): a match marks the script 'sent' with that id (never re-posted).
  #
  # - Returns at once when nothing is 'sent' (or in doubt with the filter capability): no call at all.
  # - Expired or missing JWT: no call, no state change, snapshot status 'no_credentials' ("sign in to refresh").
  # - Unreachable server: stops at the first failure (snapshot status 'unreachable').
  # - Scripts pushed to another API URL are skipped (the JWT is for the configured one).
  #
  # Recurring every 2 minutes ('outbox_remote_status' in config/recurring.yml) and enqueued by the Outbox page
  # (#enqueue_if_due). Never pushes, posts or changes anything remotely.
  #
  # == Snapshot 'outbox.remote_status' (String keys)
  #   { 'status' => 'ok' | 'no_credentials' | 'unreachable' | 'idle', 'url' =>, 'outcomes' => true | false,
  #     'checked' => n, 'executed' => n, 'applied' => n, 'failed' => n, 'missing' => n, 'resolved' => n, 'error' => }
  #
  class RemoteStatusJob < ApplicationJob # rubocop:disable Metrics/ClassLength
    queue_as :default

    limits_concurrency key: 'outbox_remote_status', to: 1, duration: 5.minutes, on_conflict: :discard

    SNAPSHOT_KEY = 'outbox.remote_status'
    # The Outbox page enqueues a check at most this often.
    DUE_AFTER = 2.minutes
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_PER_RUN = 50
    # Batch rows listed when looking up in-doubt scripts by checksum.
    LOOKUP_PER_PAGE = 100

    # Raised to stop a run (the snapshot payload to store).
    class Halt < StandardError
      attr_reader :payload

      def initialize(payload)
        @payload = payload
        super(payload['status'])
      end
    end

    class << self
      # The last Ops::Snapshot, or nil. Never raises.
      def read
        Ops.safely { Ops::Snapshot.read(SNAPSHOT_KEY) if Ops.available? }
      end

      # Enqueues a check when some script is 'sent' (or in doubt) and the last check is older than DUE_AFTER.
      # Never raises.
      def enqueue_if_due(now: Time.current)
        Ops.safely(false) do
          next false unless Ops.available? && Ops::SqlScript.in_state('sent', 'in_doubt').exists?

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

      @now = now
      @base_url = APIProxy.configured_base_url.to_s.delete_suffix('/')
      @capabilities = APICapabilities.new(base_url: @base_url)
      @counts = { 'checked' => 0, 'executed' => 0, 'applied' => 0, 'failed' => 0, 'missing' => 0, 'resolved' => 0 }
      scripts = sent_scripts
      in_doubt = in_doubt_scripts
      return store('status' => 'idle') if scripts.empty? && in_doubt.empty?

      jwt = Ops::BackgroundCredentials.jwt
      return store('status' => 'no_credentials') if jwt.blank?

      run(scripts, in_doubt, jwt)
    end

    private

    def outcomes? = @capabilities.supports?(:iq_batch_outcome)

    def on_url(relation)
      relation.where(target_api_url: [@base_url, "#{@base_url}/"])
    end

    # Sent scripts to check: all of them with outcome reporting, else only those older than EXECUTED_DELAY.
    def sent_scripts
      relation = on_url(Ops::SqlScript.sent).where.not(remote_iq_id: nil)
      relation = relation.where(Ops::SqlScript.arel_table[:pushed_at].lteq(@now - Ops::SqlScript::EXECUTED_DELAY)) unless outcomes?
      relation.ordered.limit(MAX_PER_RUN).to_a
    end

    def in_doubt_scripts
      return [] unless @capabilities.supports?(:iq_batch_filters)

      on_url(Ops::SqlScript.in_doubt).ordered.limit(MAX_PER_RUN).to_a
    end

    def run(scripts, in_doubt, jwt)
      resolve_in_doubt(in_doubt, jwt) if in_doubt.any?
      scripts.each { |script| check_one(script, jwt) }
      Outbox::Notifier.ping if @counts.except('checked').values.sum.positive?
      store('status' => 'ok')
    rescue Halt => e
      Outbox::Notifier.ping if @counts.except('checked').values.sum.positive?
      store(e.payload)
    end

    def get(url, jwt, params: nil)
      options = { method: :get, url:, jwt:, base_url: @base_url, open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }
      options[:params] = params if params
      result = APIProxy.call(**options)
      raise Halt, { 'status' => 'unreachable', 'error' => result.error_detail.to_s.truncate(300) } if result.unreachable?
      raise Halt, { 'status' => 'no_credentials' } if result.code.to_i == 401

      result
    end

    def check_one(script, jwt)
      result = get("import_queue/#{script.remote_iq_id}", jwt)
      @counts['checked'] += 1
      return script.update!(remote_checked_at: @now) unless (200..299).cover?(result.code.to_i)

      outcomes? ? apply_outcome(script, result.json) : apply_legacy(script, result.json)
    end

    # Phase 07 behaviour (API without outcomes): only a vanished row is meaningful.
    def apply_legacy(script, json)
      return script.update!(remote_checked_at: @now) unless Outbox::RemoteStatus.map(json) == :gone

      script.mark_executed_unreported!(now: @now)
      @counts['executed'] += 1
      event(script, 'outbox.executed_unreported', 'success')
    end

    def apply_outcome(script, json)
      case Outbox::RemoteStatus.map(json)
      when :applied then applied!(script)
      when :failed then failed!(script, Outbox::RemoteStatus.error_for(json))
      when :gone then missing!(script)
      else script.update!(remote_checked_at: @now)
      end
    end

    def applied!(script)
      script.mark_applied!(now: @now)
      @counts['applied'] += 1
      event(script, 'outbox.applied', 'success')
    end

    def failed!(script, error)
      rel_path = begin
        Outbox::ScriptActions.move_to_new!(script)
      rescue Outbox::Error, SystemCallError => e
        # (a file with the same name in results.new: the script stays where it is, its state says it all)
        Rails.logger.warn("[Outbox::RemoteStatusJob] #{script.filename} not moved back: #{e.message}")
        script.rel_path
      end
      script.mark_failed!(error:, rel_path:, now: @now)
      @counts['failed'] += 1
      event(script, 'outbox.failed', 'error', 'error' => error.to_s.truncate(500))
    end

    def missing!(script)
      script.mark_missing_remote!(now: @now)
      @counts['missing'] += 1
      event(script, 'outbox.missing_remote', 'warning')
    end

    # Looks the in-doubt scripts up among the server's batch rows by file checksum (base64 MD5).
    def resolve_in_doubt(scripts, jwt)
      result = get('import_queues', jwt, params: { batch_sql: true, per_page: LOOKUP_PER_PAGE })
      rows = (200..299).cover?(result.code.to_i) && result.json.is_a?(Array) ? result.json : []
      by_checksum = rows.select { |row| row.is_a?(Hash) && row['data_file_checksum'].present? }.index_by { |row| row['data_file_checksum'] }
      scripts.each { |script| resolve_one(script, by_checksum) }
    end

    def resolve_one(script, by_checksum)
      return unless script.file_exists?

      row = by_checksum[Digest::MD5.base64digest(File.binread(script.absolute_path))]
      return unless row && row['id'].to_i.positive?

      script.mark_sent!(rel_path: Outbox::ScriptActions.move_to_sent!(script), remote_iq_id: row['id'].to_i,
                        target_api_url: script.target_api_url, target_env: script.target_env,
                        pushed_at: script.pushed_at || @now)
      @counts['resolved'] += 1
      event(script, 'outbox.resolved', 'success', 'to' => 'sent', 'by' => 'checksum')
    end

    def event(script, kind, level, data = {})
      Ops.record_event!(kind:, level:, actor: 'job', season_id: script.season_id, subject_type: 'sql_script',
                        subject_key: script.id,
                        data: { 'file' => script.filename, 'import_queue_id' => script.remote_iq_id }.merge(data),
                        link_path: Rails.application.routes.url_helpers.outbox_script_path(script))
    end

    def store(payload)
      full = @counts.merge('url' => @base_url, 'outcomes' => outcomes?).merge(payload)
      Ops.safely { Ops::Snapshot.write!(SNAPSHOT_KEY, full, source: self.class.name) }
      full
    end
  end
end
