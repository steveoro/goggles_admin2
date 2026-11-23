# frozen_string_literal: true

require 'digest'

module Outbox
  #
  # = Outbox::Pusher
  #
  # Performs an Ops::PushRun (called only by Outbox::PushJob): posts each script of the run, in seq order, to
  # 'import_queue/batch_sql' of the run's target API, stopping at the first error.
  #
  # Before the first POST (any failure here aborts the run, nothing is posted):
  # - the pushing user and their API JWT (+users.jwt+, read now, valid for the local API key);
  # - a fresh ping of the target (unreachable => abort);
  # - every 'pushing' row left by an older run becomes 'in_doubt' (one push at a time: none can be live), and the
  #   Reconciler runs (files moved or edited since the click).
  #
  # Per script:
  # 1. still pending, not blocked by a lower seq (unless the run overrides the order), file present and unchanged
  #    (sha256) => otherwise the run stops;
  # 2. state 'pushing' persisted BEFORE the POST (a crash then leaves it in doubt, never re-posted);
  # 3. POST accepted (new.id > 0) => remote id, target and push time stored, file moved into results.sent/<folder>/,
  #    state 'sent' ("sent, not verified"), pages pinged;
  #    rejected or unreachable => back to 'pending' with +last_error+, run 'stopped'.
  #
  class Pusher
    ENDPOINT = 'import_queue/batch_sql'
    PING_TIMEOUTS = { open_timeout: 5, timeout: 10 }.freeze
    POST_TIMEOUTS = { open_timeout: 10, timeout: 300 }.freeze

    # Raised to stop the run at a script (message = reason).
    class Stop < StandardError; end

    attr_reader :run, :data_root

    def initialize(run:, data_root: Outbox.data_root)
      @run = run
      @data_root = Pathname.new(data_root)
    end

    # True when +jwt+ is valid for the local API static key (same check as APISession#valid_jwt?).
    def self.jwt_valid?(jwt)
      jwt.present? && GogglesDb::JWTManager.decode(jwt, Rails.application.credentials.api_static_key).present?
    rescue StandardError
      false
    end

    # Returns the run (reloaded).
    def call
      jwt = preflight!
      return run unless jwt

      event('outbox.push_started', 'info', 'count' => run.total)
      run.scripts.each do |script|
        script.data_root = data_root
        push_one(script, jwt)
        run.update!(pushed_count: run.pushed_count + 1)
      end
      run.finish!
      event('outbox.push_finished', 'success', 'pushed' => run.pushed_count)
      run
    rescue Stop => e
      stop!(@current, e.message)
    ensure
      Outbox::Notifier.ping
    end

    private

    # Returns the JWT, or nil after aborting the run.
    def preflight!
      user = GogglesDb::User.find_by(id: run.user_id)
      return abort!(I18n.t('outbox.errors.no_user')) unless user
      return abort!(I18n.t('outbox.errors.jwt_invalid')) unless self.class.jwt_valid?(user.jwt)

      ping = APIProxy.ping(run.target_api_url, **PING_TIMEOUTS)
      return abort!(I18n.t('outbox.errors.unreachable', error: ping.error_detail)) if ping.unreachable?

      expire_pushing!
      Outbox::Reconciler.call(data_root:)
      user.jwt
    end

    def expire_pushing!
      Ops::SqlScript.pushing.find_each do |script|
        script.mark_in_doubt!
        Ops.record_event!(kind: 'outbox.in_doubt', level: 'warning', season_id: script.season_id,
                          subject_type: 'sql_script', subject_key: script.id, data: { 'file' => script.filename })
      end
    end

    def push_one(script, jwt)
      @current = script.reload
      check!(script)
      script.update!(target_api_url: run.target_api_url, target_env: run.target_env)
      script.mark_pushing!
      result = File.open(script.absolute_path, 'rb') do |file|
        APIProxy.call(method: :post, url: ENDPOINT, jwt:, base_url: run.target_api_url, payload: { data_file: file },
                      **POST_TIMEOUTS)
      end
      remote_id = result.json.is_a?(Hash) ? result.json.dig('new', 'id').to_i : 0
      remote_id.positive? ? accepted!(script, remote_id) : rejected!(script, result)
    end

    def check!(script) # rubocop:disable Metrics/AbcSize
      raise Stop, I18n.t('outbox.errors.not_pending', file: script.filename, state: script.state_label) unless script.pending?

      blockers = script.blockers.to_a
      if blockers.any? && !run.override_order
        raise Stop, I18n.t('outbox.errors.blocked', file: script.filename, blockers: blockers.first(3).map(&:filename).join(', '))
      end
      raise Stop, I18n.t('outbox.errors.file_missing', path: script.rel_path) unless script.file_exists?

      sha = Digest::SHA256.file(script.absolute_path).hexdigest
      raise Stop, I18n.t('outbox.errors.changed', expected: script.sha256.first(12), found: sha.first(12)) if sha != script.sha256
    end

    def accepted!(script, remote_id)
      # (remote id stored before the move: if the move fails the in-doubt row still knows it)
      script.update!(remote_iq_id: remote_id, pushed_at: Time.current)
      script.mark_sent!(rel_path: Outbox::ScriptActions.move_to_sent!(script), remote_iq_id: remote_id,
                        target_api_url: run.target_api_url, target_env: run.target_env, pushed_at: script.pushed_at)
      push_event(script, 'push.uploaded', 'success', 'import_queue_id' => remote_id)
      Outbox::Notifier.ping
    end

    def rejected!(script, result)
      error = result.error_detail.to_s
      script.mark_rejected!(error)
      push_event(script, 'push.failed', 'error', 'error' => error.truncate(500))
      raise Stop, I18n.t('outbox.errors.rejected', error: error.truncate(300))
    end

    def abort!(error)
      run.abort!(error)
      event('outbox.push_aborted', 'error', 'error' => error.to_s.truncate(500))
      nil
    end

    def stop!(script, error)
      run.stop!(script:, error:)
      event('outbox.push_stopped', 'error', 'error' => error.to_s.truncate(500), 'file' => script&.filename)
      run
    end

    def event(kind, level, data)
      Ops.record_event!(kind:, level:, actor: 'operator', subject_type: 'push_run', subject_key: run.id,
                        data: data.compact, link_path: Rails.application.routes.url_helpers.outbox_path)
    end

    # Same 'push.*' events (and payload) as the former Push page.
    def push_event(script, kind, level, data)
      Ops.record_event!(kind:, level:, actor: 'operator', season_id: script.season_id, subject_type: 'sql_file',
                        subject_key: script.rel_path,
                        data: { 'file' => script.filename, 'path' => script.rel_path, 'push_run_id' => run.id }.merge(data),
                        link_path: Rails.application.routes.url_helpers.outbox_path(focus: script.filename))
    end
  end
end
