# frozen_string_literal: true

module Outbox
  #
  # = Outbox::ScriptActions
  #
  # The operator actions of the Outbox page on one Ops::SqlScript (OutboxController), each one a click:
  # hold, release, "Apply locally", discard, resolve an in-doubt push. Each records an Ops::Event and pings
  # the open pages. Invalid moves raise Ops::SqlScript::InvalidTransition (shown as a flash by the controller).
  #
  # Also the shared file move into results.sent (#move_to_sent!), used by Outbox::Pusher.
  #
  module ScriptActions
    # Held reasons that "Apply locally" resolves.
    APPLY_REASONS = %w[not_applied_locally local_apply_failed].freeze

    module_function

    def hold!(script)
      script.hold!(reason: 'operator')
      done(script, 'outbox.held')
    end

    # held -> pending; +force+ ("push without local apply") for a script not applied locally.
    def release!(script, force: false)
      script.release!(force:)
      done(script, 'outbox.released', { 'forced' => force.presence })
    end

    # True when "Apply locally" is offered: held because not applied (or failed), or pending with an unknown apply.
    def can_apply_locally?(script)
      return false unless script.file_exists?
      return APPLY_REASONS.include?(script.held_reason) if script.held?

      script.pending? && script.applied_locally != true
    end

    # Runs the script on the local DB (LocalDb::SqlRunner); on success the script becomes pending in local-apply
    # order (Outbox::Writer.mark_applied_locally!), on failure it stays held ('local_apply_failed').
    # Returns the LocalDb::SqlRunner::Result.
    def apply_locally!(script, runner: LocalDb::SqlRunner)
      unless can_apply_locally?(script)
        raise Ops::SqlScript::InvalidTransition,
              I18n.t('outbox.errors.invalid_transition', event: :apply_locally, state: script.state)
      end

      result = runner.call(path: script.absolute_path)
      if result.success?
        Outbox::Writer.mark_applied_locally!(script, data_root: script.data_root)
        done(script, 'outbox.applied_locally', { 'duration' => result.duration.round(2) })
      else
        Outbox::Writer.mark_apply_failed!(script, error: result.stderr, data_root: script.data_root)
        done(script, 'outbox.apply_failed', { 'error' => result.stderr.to_s.truncate(500) }, level: 'error')
      end
      result
    end

    # pending, held, in_doubt -> discarded: the file goes to results.new/discarded/<folder>/ (never scanned).
    def discard!(script, note:)
      raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.errors.note_required') if note.blank?

      rel_path = move_file(script, File.join(Outbox::NEW_DIR, Outbox::DISCARDED_DIR, script.folder, script.filename))
      script.mark_discarded!(note:, rel_path:)
      done(script, 'outbox.discarded', { 'note' => note.to_s.truncate(200) })
    end

    # in_doubt -> sent (with the remote import queue id), pending, or discarded (with a note).
    def resolve!(script, to:, remote_iq_id: nil, note: nil)
      raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.errors.invalid_transition', event: :resolve, state: script.state) unless script.in_doubt?

      case to.to_s
      when 'sent'
        id = remote_iq_id.to_i
        raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.resolve_form.remote_id') unless id.positive?

        script.mark_sent!(rel_path: move_to_sent!(script), remote_iq_id: id, target_api_url: script.target_api_url,
                          target_env: script.target_env, pushed_at: script.pushed_at || Time.current)
      when 'pending'
        script.update!(state: 'pending')
      when 'discarded'
        return discard!(script, note:)
      else
        raise Ops::SqlScript::InvalidTransition, I18n.t('outbox.errors.invalid_transition', event: to, state: script.state)
      end
      done(script, 'outbox.resolved', { 'to' => to.to_s, 'remote_iq_id' => remote_iq_id.presence })
    end

    # Moves the file of a script from results.new to the same path under results.sent; returns the new rel_path
    # (unchanged when the file is already there). Never overwrites an existing file.
    def move_to_sent!(script)
      return script.rel_path unless script.in_new_dir?

      move_file(script, script.rel_path.sub(%r{\A#{Regexp.escape(Outbox::NEW_DIR)}/}o, "#{Outbox::SENT_DIR}/"))
    end

    # Moves the script file to +rel_path+ (under its data root); returns +rel_path+. A missing source file is not
    # an error (the row follows anyway).
    def move_file(script, rel_path)
      source = script.absolute_path
      dest = script.data_root.join(rel_path)
      Outbox.guard_test_path!(dest)
      return rel_path if source == dest || !source.exist?
      raise Outbox::Error, "'#{dest}' already exists" if dest.exist?

      FileUtils.mkdir_p(dest.dirname)
      File.rename(source, dest)
      rel_path
    end

    def done(script, kind, data = {}, level: 'info')
      Ops.record_event!(kind:, level:, actor: 'operator', season_id: script.season_id, subject_type: 'sql_script',
                        subject_key: script.id, data: { 'file' => script.filename }.merge(data.compact),
                        link_path: Rails.application.routes.url_helpers.outbox_script_path(script))
      Outbox::Notifier.ping
      script
    end
    private_class_method :done
  end
end
