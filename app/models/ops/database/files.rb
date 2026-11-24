# frozen_string_literal: true

module Ops
  class Database
    #
    # = Ops::Database::Files
    #
    # File-level helpers of Ops::Database (backups, deletion, server PID check), extended by it.
    #
    module Files
      # Copies the DB file (VACUUM INTO) to '<backup_dir>/ops-<env>-<label>-<UTC timestamp>.sqlite3',
      # keeping only the newest BACKUPS_KEPT files of the environment.
      # Returns the backup Pathname, or nil when there is nothing to back up.
      def backup!(label: 'manual')
        config = db_config
        return unless config && File.exist?(database_path(config))

        dir = backup_folder
        FileUtils.mkdir_p(dir)
        safe_label = label.to_s.gsub(/[^\w-]+/, '_').presence || 'manual'
        base = "ops-#{Rails.env}-#{safe_label}-#{Time.now.utc.strftime('%Y%m%d-%H%M%S%L')}"
        dest = dir.join("#{base}.sqlite3")
        dest = dir.join("#{base}-#{SecureRandom.hex(2)}.sqlite3") while dest.exist? # (VACUUM INTO never overwrites)
        with_isolated_connection(config) { |conn| conn.execute("VACUUM INTO #{conn.quote(dest.to_s)}") }
        rotate_backups!(dir)
        dest
      end

      # Backup files of the current environment, newest first.
      def backups(dir = backup_folder)
        Dir.glob(dir.join("ops-#{Rails.env}-*.sqlite3")).sort_by { |f| [File.mtime(f).to_f, f] }.reverse
      end

      # Deletes the DB file and its SQLite companions (-wal, -shm, -journal). Rake-only (see 'ops:reset').
      def delete_files!
        path = database_path
        return unless path

        Ops::ApplicationRecord.connection_pool.disconnect!
        FileUtils.rm_f(['', '-wal', '-shm', '-journal'].map { |suffix| "#{path}#{suffix}" })
        reset_state!
      end

      # True when the server PID file points to a live process.
      def server_running?
        pid_file = Pathname.new(server_pid_file || Rails.root.join('tmp/pids/server.pid'))
        return false unless pid_file.file?

        pid = pid_file.read.to_i
        return false unless pid.positive?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      private

      def backup_folder
        Pathname.new(backup_dir || Rails.root.join('db/dump'))
      end

      def rotate_backups!(dir)
        backups(dir).drop(Ops::Database::BACKUPS_KEPT).each { |f| FileUtils.rm_f(f) }
      end
    end
  end
end
