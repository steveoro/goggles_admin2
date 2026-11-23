# frozen_string_literal: true

module Ops
  #
  # = Ops::SqlScript
  #
  # One SQL script of the Outbox registry (ops DB, table 'sql_scripts'); see Outbox and docs/outbox.md.
  #
  # Written by Outbox::Writer (every producer) and Outbox::Reconciler (files found on disk); changed by the
  # operator actions (Outbox::ScriptActions), Outbox::Pusher and Outbox::RemoteStatusJob, always through the
  # transition methods below (plain methods with guard clauses: an invalid move raises InvalidTransition).
  #
  # == State machine
  #   pending <-> held                (hold / release, "Apply locally")
  #   pending  -> pushing -> sent      (POST accepted: file moved to results.sent/<folder>/; 'sent' = queued on the server)
  #   pushing  -> pending              (POST rejected or unreachable: the run stops)
  #   pushing  -> in_doubt             (stale for STALE_PUSHING_AFTER without a live run; never re-posted)
  #   in_doubt -> sent | pending | discarded (operator; or 'sent' by checksum, Outbox::RemoteStatusJob)
  # Phase 08 (the server reports the outcome, API capability 'iq_batch_outcome'; see Outbox::RemoteStatus):
  #   sent     -> applied              (run on the server)
  #   sent     -> failed               (the server error in remote_error; file moved back to results.new/<folder>/)
  #   failed   -> sent                 (Retry in place: file unchanged)
  #   sent, failed -> pending          (Withdraw: the queued server row is deleted; file back in results.new)
  #   failed   -> withdrawn            (Discard: server row deleted, file moved to results.new/discarded/)
  #   sent     -> missing_remote       (the server row is gone although the server reports outcomes: "deleted on server")
  #   sent     -> executed_unreported  (row gone, API without outcomes: after EXECUTED_DELAY)
  #   pending, held -> discarded       (operator, note required)
  #   any      -> missing              (file gone on rescan; back to the previous state when it reappears)
  #   legacy_sent, archived: terminal (one-time import, files moved by hand)
  #
  # == Attributes
  # - seq: global local-apply order (unique); rel_path: path under the data root (unique), e.g.
  #   'results.new/262/0490-<base>-lt4.sql'; filename; folder ('262', 'misc', 'normalize', ...); season_id;
  # - kind (Outbox::Kinds::ALL); sha256, byte_size, file_mtime; state (STATES), previous_state (before 'missing');
  # - held_reason (HELD_REASONS); applied_locally (nil = unknown); single_transaction;
  # - origin (JSON: producer, source_base, fin_event_id, meeting_id, calendar_id, task, args, ...);
  # - target_api_url, target_env, remote_iq_id, push_attempts, pushed_at, remote_checked_at, resolved_at;
  # - remote_outcome_at (applied/failed seen), remote_error (server error text, REMOTE_ERROR_LIMIT), withdrawn_at;
  # - last_error (4 KB max), changed_after_push, note.
  #
  class SqlScript < ApplicationRecord # rubocop:disable Metrics/ClassLength
    self.table_name = 'sql_scripts'

    # Raised by the transition methods when the move is not allowed from the current state.
    class InvalidTransition < StandardError; end

    STATES = %w[
      pending held pushing in_doubt sent applied failed missing_remote executed_unreported
      legacy_sent archived discarded withdrawn missing
    ].freeze
    NEEDS_PUSH_STATES = %w[pending held pushing in_doubt].freeze
    ON_SERVER_STATES = %w[failed sent applied missing_remote executed_unreported].freeze
    HISTORY_STATES = %w[legacy_sent archived discarded withdrawn missing].freeze
    # States blocking the push of a higher seq (a held script never blocks; a failed one does: the server stops
    # at it, and a fix pushed later must keep the id order).
    BLOCKING_STATES = %w[pending pushing in_doubt failed].freeze
    # States whose file is expected under results.new
    NEW_DIR_STATES = %w[pending held pushing in_doubt failed].freeze
    HELD_REASONS = %w[not_applied_locally local_apply_failed operator legacy_folder].freeze
    LAST_ERROR_LIMIT = 4.kilobytes
    # (The server keeps up to 60 KB of stderr: the start of it is what matters)
    REMOTE_ERROR_LIMIT = 16.kilobytes
    # A 'pushing' row older than this (with no live run) becomes 'in_doubt'.
    STALE_PUSHING_AFTER = 10.minutes
    # A 'sent' script whose remote row is gone becomes 'executed_unreported' only after this delay from the push.
    EXECUTED_DELAY = 5.minutes

    validates :seq, :rel_path, :filename, :folder, :kind, :sha256, :state, presence: true
    validates :seq, :rel_path, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :kind, inclusion: { in: Outbox::Kinds::ALL }
    validates :held_reason, inclusion: { in: HELD_REASONS }, allow_nil: true

    scope :ordered, -> { order(:seq) }
    scope :in_state, ->(*states) { where(state: states.flatten.map(&:to_s)) }
    scope :needs_push, -> { in_state(NEEDS_PUSH_STATES).ordered }
    scope :on_server, -> { in_state(ON_SERVER_STATES).ordered }
    scope :history, -> { in_state(HISTORY_STATES).ordered }
    scope :pending, -> { in_state('pending') }
    scope :held, -> { in_state('held') }
    scope :pushing, -> { in_state('pushing') }
    scope :in_doubt, -> { in_state('in_doubt') }
    scope :sent, -> { in_state('sent') }
    scope :failed, -> { in_state('failed') }
    scope :applied, -> { in_state('applied') }
    scope :missing_remote, -> { in_state('missing_remote') }
    # Scripts of a season folder or of the cross-season folders (folder names: '262', 'misc', ...).
    scope :in_folders, ->(*folders) { where(folder: folders.flatten.map(&:to_s)) }

    # Data root the row's rel_path is relative to (set by the Writer/Reconciler that loaded it; default Outbox.data_root).
    attr_writer :data_root

    class << self
      # Kinds of the registered scripts among +rel_paths+, as { rel_path => kind } (one query).
      def kinds_for(rel_paths)
        paths = Array(rel_paths).map(&:to_s).uniq
        return {} if paths.empty?

        where(rel_path: paths).pluck(:rel_path, :kind).to_h
      end

      # Kind of the script registered at +rel_path+, or nil.
      def kind_for(rel_path)
        kinds_for([rel_path])[rel_path.to_s]
      end

      # Scripts in a blocking state with a lower seq than +seq+.
      def blocking_before(seq)
        in_state(BLOCKING_STATES).where(arel_table[:seq].lt(seq)).ordered
      end
    end

    def data_root
      Pathname.new(@data_root || Outbox.data_root)
    end

    # Absolute Pathname of the file.
    def absolute_path
      data_root.join(rel_path)
    end

    def file_exists?
      absolute_path.file?
    end

    # Under results.new (pushable) or results.sent.
    def in_new_dir? = rel_path.to_s.start_with?("#{Outbox::NEW_DIR}/")
    def in_sent_dir? = rel_path.to_s.start_with?("#{Outbox::SENT_DIR}/")

    STATES.each do |name|
      define_method(:"#{name}?") { state == name }
    end

    def needs_push? = NEEDS_PUSH_STATES.include?(state)
    def on_server? = ON_SERVER_STATES.include?(state)
    def history? = HISTORY_STATES.include?(state)

    # Lower-seq scripts in a blocking state (pending, pushing, in_doubt).
    def blockers
      self.class.blocking_before(seq)
    end

    def blocked?
      blockers.exists?
    end

    # True for a 'pushing' row older than STALE_PUSHING_AFTER.
    def stale_pushing?(now: Time.current)
      pushing? && updated_at.present? && updated_at < now - STALE_PUSHING_AFTER
    end

    # Operator-facing state label (e.g. "sent, not verified").
    def state_label
      I18n.t("outbox.states.#{state}", default: state.humanize)
    end

    def kind_label
      I18n.t("outbox.kinds.#{kind}", default: kind.humanize)
    end

    def origin_data
      origin.is_a?(Hash) ? origin : {}
    end

    def last_error=(value)
      super(value&.to_s&.truncate(LAST_ERROR_LIMIT))
    end

    def remote_error=(value)
      super(value&.to_s&.truncate(REMOTE_ERROR_LIMIT))
    end

    # Lower-seq 'failed' scripts pushed to the same API (the server runs nothing after them), or none.
    def failed_before
      return self.class.none unless sent? || failed?

      self.class.failed.where(target_api_url:).where(self.class.arel_table[:seq].lt(seq)).ordered
    end

    # == Transitions (each one saves the row; an invalid move raises InvalidTransition)

    # pending -> held
    def hold!(reason: 'operator')
      ensure_state!(%w[pending], :hold)
      update!(state: 'held', held_reason: reason.to_s)
    end

    # held -> pending: allowed when applied locally, or with force ("push without local apply").
    def release!(force: false)
      ensure_state!(%w[held], :release)
      raise InvalidTransition, I18n.t('outbox.errors.not_applied_locally') unless applied_locally? || force

      update!(state: 'pending', held_reason: nil)
    end

    # pending -> pushing (persisted before the POST)
    def mark_pushing!
      ensure_state!(%w[pending], :push)
      update!(state: 'pushing', push_attempts: push_attempts.to_i + 1, last_error: nil)
    end

    # pushing -> sent (after the file was moved to +rel_path+ under results.sent)
    def mark_sent!(rel_path:, remote_iq_id:, target_api_url:, target_env:, pushed_at: Time.current)
      ensure_state!(%w[pushing in_doubt], :sent)
      update!(state: 'sent', rel_path:, remote_iq_id:, target_api_url:, target_env:, pushed_at:,
              last_error: nil, changed_after_push: false)
    end

    # pushing -> pending (POST rejected or server unreachable)
    def mark_rejected!(error)
      ensure_state!(%w[pushing], :reject)
      update!(state: 'pending', last_error: error)
    end

    # pushing -> in_doubt (stale, never re-posted automatically)
    def mark_in_doubt!
      ensure_state!(%w[pushing], :in_doubt)
      update!(state: 'in_doubt')
    end

    # sent -> executed_unreported (remote import queue row gone, API without outcome reporting)
    def mark_executed_unreported!(now: Time.current)
      ensure_state!(%w[sent], :executed_unreported)
      update!(state: 'executed_unreported', remote_checked_at: now, resolved_at: now)
    end

    # sent -> applied (the server ran it)
    def mark_applied!(now: Time.current)
      ensure_state!(%w[sent], :applied)
      update!(state: 'applied', remote_checked_at: now, remote_outcome_at: now, resolved_at: now, remote_error: nil)
    end

    # sent -> failed (the server error text; the file was moved back to +rel_path+ under results.new)
    def mark_failed!(error:, rel_path: self.rel_path, now: Time.current)
      ensure_state!(%w[sent], :failed)
      update!(state: 'failed', rel_path:, remote_error: error.presence || '?', remote_checked_at: now, remote_outcome_at: now,
              resolved_at: nil)
    end

    # failed -> sent (Retry in place: the server row was reset; the file moved back to +rel_path+ under results.sent)
    def mark_retried!(rel_path:, now: Time.current)
      ensure_state!(%w[failed], :retry)
      update!(state: 'sent', rel_path:, last_error: remote_error, remote_error: nil, remote_outcome_at: nil,
              pushed_at: now, push_attempts: push_attempts.to_i + 1, changed_after_push: false)
    end

    # sent, failed -> pending (Withdraw: the server row was deleted; the file is back at +rel_path+ under results.new)
    def mark_withdrawn!(rel_path:, now: Time.current)
      ensure_state!(%w[sent failed], :withdraw)
      update!(state: 'pending', rel_path:, withdrawn_at: now, remote_iq_id: nil, last_error: remote_error.presence || last_error,
              remote_error: nil, remote_outcome_at: nil, resolved_at: nil)
    end

    # failed -> withdrawn (Discard of a failed script: server row deleted, file moved to +rel_path+ under discarded/)
    def mark_abandoned!(note:, rel_path:, now: Time.current)
      ensure_state!(%w[failed], :discard)
      raise InvalidTransition, I18n.t('outbox.errors.note_required') if note.blank?

      update!(state: 'withdrawn', rel_path:, note: note.to_s.strip, withdrawn_at: now, resolved_at: now)
    end

    # sent -> missing_remote (the server row is gone although the server reports outcomes)
    def mark_missing_remote!(now: Time.current)
      ensure_state!(%w[sent], :missing_remote)
      update!(state: 'missing_remote', remote_checked_at: now, resolved_at: now)
    end

    # pending, held, in_doubt -> discarded (file already moved to +rel_path+)
    def mark_discarded!(note:, rel_path: self.rel_path)
      ensure_state!(%w[pending held in_doubt], :discard)
      raise InvalidTransition, I18n.t('outbox.errors.note_required') if note.blank?

      update!(state: 'discarded', note: note.to_s.strip, rel_path:, held_reason: nil, resolved_at: Time.current)
    end

    # any (but missing/discarded) -> missing
    def mark_missing!
      return self if missing? || discarded?

      update!(previous_state: state, state: 'missing')
    end

    # missing -> previous state (the file reappeared)
    def mark_reappeared!
      ensure_state!(%w[missing], :reappear)
      update!(state: STATES.include?(previous_state) ? previous_state : 'pending', previous_state: nil)
    end

    private

    def ensure_state!(allowed, event)
      return if allowed.include?(state)

      raise InvalidTransition, I18n.t('outbox.errors.invalid_transition', event:, state:)
    end
  end
end
