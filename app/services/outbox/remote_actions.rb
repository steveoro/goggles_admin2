# frozen_string_literal: true

require 'digest'

module Outbox
  #
  # = Outbox::RemoteActions
  #
  # The operator actions of the Outbox page that change the remote import queue (phase 08; OutboxController, one
  # click each, with the operator's own API JWT). They need an API reporting the batch outcomes (capability
  # 'iq_batch_outcome', see APICapabilities): against an older API they raise Outbox::Error.
  #
  # - retry!:    a failed script whose file is unchanged => <tt>PUT import_queue/:id</tt>
  #              <tt>{ error_messages: '', process_runs: 0 }</tt> (the server runs it again, in place, keeping its id
  #              order); file back to results.sent, state 'sent'. An edited file needs Withdraw first.
  # - withdraw!: a failed or queued script AND every later 'sent' script pushed to the same API => each server row
  #              that has not run is deleted (<tt>DELETE import_queue/:id</tt>, highest seq first), the files go back to
  #              results.new and the scripts to 'pending' (so a re-pushed fix keeps the id order on the server).
  #              Stops at the first row that already ran (or a failed call): the scripts before it stay as they are.
  # - abandon!:  Discard of a failed script => its server row is deleted, the file moved to results.new/discarded/,
  #              state 'withdrawn' (note required). The later scripts stay queued and run.
  #
  # Each action records an Ops::Event and pings the open pages. The calls are logged as Ops::RemoteWrite rows
  # (endpoint 'import_queue/<id>'), which the DB sync verdict ignores (they change the queue, not the data).
  #
  module RemoteActions
    TIMEOUTS = { open_timeout: 5, timeout: 20 }.freeze

    module_function

    # Returns the script (state 'sent').
    def retry!(script, jwt:)
      ensure_capability!(script)
      ensure_state!(script, %w[failed], :retry)
      raise Outbox::Error, I18n.t('outbox.errors.file_missing', path: script.rel_path) unless script.file_exists?
      raise Outbox::Error, I18n.t('outbox.errors.retry_changed') if changed?(script)

      result = call(script, :put, jwt:, payload: { error_messages: '', process_runs: 0 })
      raise Outbox::Error, I18n.t('outbox.errors.remote_call', error: result.error_detail.to_s.truncate(300)) unless success?(result)

      script.mark_retried!(rel_path: Outbox::ScriptActions.move_to_sent!(script))
      done(script, 'outbox.retried', { 'import_queue_id' => script.remote_iq_id })
    end

    # Returns the withdrawn scripts (now 'pending'), highest seq first. Raises Outbox::Error when it had to stop
    # (the message says why; the scripts withdrawn before the stop stay withdrawn).
    def withdraw!(script, jwt:)
      ensure_capability!(script)
      ensure_state!(script, %w[failed sent], :withdraw)

      withdrawn = []
      withdraw_list(script).each do |item|
        withdraw_one!(item, jwt:)
        withdrawn << item
      end
      withdrawn
    rescue Outbox::Error => e
      raise Outbox::Error, I18n.t('outbox.errors.withdraw_stopped', count: withdrawn.size, error: e.message) if withdrawn&.any?

      raise
    end

    # Returns the script (state 'withdrawn').
    def abandon!(script, jwt:, note:)
      ensure_capability!(script)
      ensure_state!(script, %w[failed], :discard)
      raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.errors.note_required') if note.blank?

      delete_remote!(script, jwt:, allowed: %i[failed queued gone])
      rel_path = Outbox::ScriptActions.move_file(script, File.join(Outbox::NEW_DIR, Outbox::DISCARDED_DIR, script.folder, script.filename))
      script.mark_abandoned!(note:, rel_path:)
      done(script, 'outbox.abandoned', { 'note' => note.to_s.truncate(200) })
    end

    # The script plus the later 'sent' scripts pushed to the same API, highest seq first.
    def withdraw_list(script)
      later = Ops::SqlScript.sent.where(target_api_url: script.target_api_url)
                            .where(Ops::SqlScript.arel_table[:seq].gt(script.seq)).where.not(id: script.id).to_a
      [script, *later].sort_by { |item| -item.seq }.each { |item| item.data_root = script.data_root }
    end

    def withdraw_one!(script, jwt:)
      delete_remote!(script, jwt:, allowed: %i[queued failed gone])
      script.mark_withdrawn!(rel_path: Outbox::ScriptActions.move_to_new!(script))
      done(script, 'outbox.withdrawn', { 'import_queue_id' => script.remote_iq_id_before_last_save })
    end

    # Deletes the server row of +script+ when its outcome is in +allowed+ (:gone: nothing to delete).
    def delete_remote!(script, jwt:, allowed:)
      raise Outbox::Error, I18n.t('outbox.errors.no_remote_id', file: script.filename) if script.remote_iq_id.blank?

      outcome = remote_outcome!(script, jwt:)
      unless allowed.include?(outcome)
        raise Outbox::Error, I18n.t('outbox.errors.already_ran', file: script.filename, outcome: I18n.t("outbox.remote_outcomes.#{outcome}"))
      end
      return if outcome == :gone

      result = call(script, :delete, jwt:)
      raise Outbox::Error, I18n.t('outbox.errors.remote_call', error: result.error_detail.to_s.truncate(300)) unless success?(result)
    end

    # The current outcome of the script's server row (Outbox::RemoteStatus); raises Outbox::Error when unknown.
    def remote_outcome!(script, jwt:)
      read = call(script, :get, jwt:)
      raise Outbox::Error, I18n.t('outbox.errors.remote_call', error: read.error_detail.to_s.truncate(300)) unless success?(read)

      Outbox::RemoteStatus.map(read.json)
    end

    def call(script, method, jwt:, payload: nil)
      options = { method:, url: "import_queue/#{script.remote_iq_id}", jwt:, base_url: script.target_api_url, **TIMEOUTS }
      options[:payload] = payload if payload
      APIProxy.call(**options)
    end

    def success?(result)
      !result.unreachable? && (200..299).cover?(result.code.to_i)
    end

    # True when the file differs from the pushed one (or the Reconciler flagged it).
    def changed?(script)
      script.changed_after_push? || Digest::SHA256.file(script.absolute_path).hexdigest != script.sha256
    end

    def ensure_capability!(script)
      return if APICapabilities.new(base_url: script.target_api_url).supports?(:iq_batch_outcome)

      raise Outbox::Error, I18n.t('outbox.errors.no_outcome_capability')
    end

    def ensure_state!(script, allowed, event)
      return if allowed.include?(script.state)

      raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.errors.invalid_transition', event:, state: script.state)
    end

    def done(script, kind, data = {})
      Ops.record_event!(kind:, level: 'info', actor: 'operator', season_id: script.season_id, subject_type: 'sql_script',
                        subject_key: script.id, data: { 'file' => script.filename }.merge(data.compact),
                        link_path: Rails.application.routes.url_helpers.outbox_script_path(script))
      Outbox::Notifier.ping
      script
    end
    private_class_method :withdraw_list, :withdraw_one!, :delete_remote!, :remote_outcome!, :call, :success?, :changed?,
                         :ensure_capability!,
                         :ensure_state!, :done
  end
end
