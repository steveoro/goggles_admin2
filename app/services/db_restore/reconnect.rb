# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Reconnect
  #
  # After a guided restore every process still holds MySQL connections to the dropped database (MariaDB unsets
  # the default database of a session when it is dropped: "No database selected"). The restore bumps the ops
  # setting 'db_epoch' (Ops::Setting.db_epoch); each process compares it with the epoch its primary pool last saw
  # and disconnects the pool once when it changed (the next query reconnects to the new database).
  #
  # Called by DbRestoreGuard (each request) and DbRestore::JobGuard (each job). The seen epoch is kept on the pool
  # object itself, so it survives a code reload; a new pool starts fresh connections anyway. The new epoch is recorded
  # only after a successful disconnect: a failed one is retried by the next call. Never raises.
  # (+ConnectionPool#disconnect!+ is +disconnect(false)+: it doesn't raise on an acquisition timeout, it takes the
  # connections still checked out by other threads.)
  #
  module Reconnect
    EPOCH_IVAR = :@goggles_db_restore_epoch
    MUTEX = Mutex.new

    module_function

    # Disconnects the primary pool when the DB epoch changed since this pool last looked; returns true when it did.
    # +epoch+: the current Ops::Setting.db_epoch when the caller already read it.
    def check!(epoch = nil)
      epoch ||= Ops.safely { Ops::Setting.db_epoch if Ops.available? }
      return false if epoch.nil?

      pool = ActiveRecord::Base.connection_pool
      MUTEX.synchronize do
        seen = pool.instance_variable_get(EPOCH_IVAR)
        return false if seen == epoch.to_i

        if seen.nil? # (first look of this pool: its connections are fresh)
          pool.instance_variable_set(EPOCH_IVAR, epoch.to_i)
          return false
        end

        pool.disconnect!
        pool.instance_variable_set(EPOCH_IVAR, epoch.to_i)
        Rails.logger.info("[DbRestore::Reconnect] DB epoch #{seen} -> #{epoch}: MySQL pool disconnected")
        true
      end
    rescue StandardError => e
      Rails.logger.warn("[DbRestore::Reconnect] #{e.class}: #{e.message}")
      false
    end

    # Marks +epoch+ as seen by the primary pool (its connections are already fresh).
    def remember!(epoch)
      MUTEX.synchronize { ActiveRecord::Base.connection_pool.instance_variable_set(EPOCH_IVAR, epoch.to_i) }
    end

    # Forgets the seen epoch (the next check only records it). Used by the specs after each example: a rolled back
    # epoch change must not make the next example disconnect its pinned test connection.
    def forget!
      pool = ActiveRecord::Base.connection_pool
      MUTEX.synchronize { pool.remove_instance_variable(EPOCH_IVAR) if pool.instance_variable_defined?(EPOCH_IVAR) }
    end
  end
end
