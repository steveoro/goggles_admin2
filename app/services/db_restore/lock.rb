# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Lock
  #
  # The guided-restore lock (phase 14; interface in docs/plans/done/00-ops-console-masterplan-contracts.md): held from the typed confirmation until
  # the post-steps finish (or an explicit Abandon), also through an interrupted load. Stored only in the ops DB
  # (Ops::Setting 'db_restore.lock' => { 'run_id', 'since' }), which a restore never touches: without the ops DB
  # there is no lock (and the wizard refuses to start).
  #
  # Active only while the named Ops::RestoreRun is in Ops::RestoreRun::LOCKING_STATUSES (a setting left behind by a
  # finished run counts as released).
  #
  # Readers: DbRestoreGuard (every request), DbRestore::JobGuard (every job), DataFix::Guards (09), the Outbox push,
  # Maintenance::RunJob (11). Never raises for a reader.
  #
  # == Usage
  #   DbRestore::Lock.active?          # => true while a run is confirmed..post_steps (or interrupted)
  #   DbRestore::Lock.current_run      # => Ops::RestoreRun or nil
  #   DbRestore::Lock.acquire!(run)    # ops transaction; raises DbRestore::Lock::HeldError if another run holds it
  #   DbRestore::Lock.release!(run)
  #
  module Lock
    SETTING_KEY = 'db_restore.lock'

    # Raised by acquire! when another run holds the lock.
    class HeldError < StandardError; end

    module_function

    def active?
      current_run.present?
    end

    # The Ops::RestoreRun holding the lock, or nil (also without the ops DB).
    def current_run
      Ops.safely { holder_run(Ops::Setting.fetch(SETTING_KEY)) if Ops.available? }
    end

    # Time the lock was taken (or nil).
    def since
      value = Ops.safely { Ops::Setting.fetch(SETTING_KEY) if Ops.available? }
      value.is_a?(Hash) && value['since'].present? ? Time.zone.parse(value['since'].to_s) : nil
    rescue ArgumentError
      nil
    end

    # Takes the lock for +run+ (idempotent for the same run). Raises HeldError when another run holds it, and
    # Ops::NotConfiguredError / ActiveRecord errors without a working ops DB (the caller refuses then).
    def acquire!(run) # rubocop:disable Naming/PredicateMethod
      raise ArgumentError, 'acquire! needs a saved Ops::RestoreRun' unless run.is_a?(Ops::RestoreRun) && run.persisted?

      Ops::ApplicationRecord.transaction do
        holder = holder_run(Ops::Setting.fetch(SETTING_KEY))
        raise HeldError, I18n.t('db_restore.lock.held', id: holder.id) if holder && holder.id != run.id

        Ops::Setting.store!(SETTING_KEY, { 'run_id' => run.id, 'since' => Time.current.utc.iso8601 }) unless holder
      end
      true
    end

    # Releases the lock when +run+ holds it (or when the holder is no longer locking); returns true when released.
    def release!(run)
      Ops::ApplicationRecord.transaction do
        value = Ops::Setting.fetch(SETTING_KEY)
        next false unless value.is_a?(Hash)
        next false unless value['run_id'].to_i == run.id || holder_run(value).nil?

        Ops::Setting.where(key: SETTING_KEY).delete_all.positive?
      end
    end

    # (The run named by the setting value, when still locking.)
    def holder_run(value)
      run_id = value.is_a?(Hash) ? value['run_id'] : nil
      return if run_id.blank?

      run = Ops::RestoreRun.find_by(id: run_id)
      run if run&.locking?
    end
  end
end
