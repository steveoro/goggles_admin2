# frozen_string_literal: true

#
# = Guided local DB restore: terminal helpers (phase 14, see docs/db_restore.md)
#
#   The restore itself runs from the web wizard (/db_restore/new); these tasks only read the ops DB, or release a
#   lock left behind when the web UI is not usable. They never touch the MySQL DB.
#
#-- ---------------------------------------------------------------------------
#++

namespace :db_restore do
  desc <<~DESC
    Shows the guided-restore lock and the last restore runs (ops DB only).

    Usage:
      > bin/rails db_restore:status

  DESC
  task status: :environment do
    abort('The ops DB is not available (bin/rails ops:prepare).') unless Ops.available?

    run = DbRestore::Lock.current_run
    puts(run ? "- Lock held by run ##{run.id} (#{run.status}, step #{run.step}) since #{DbRestore::Lock.since}" : '- No restore in progress.')
    Ops::RestoreRun.recent.limit(10).each do |row|
      puts("  ##{row.id} #{row.created_at.localtime.strftime('%Y-%m-%d %H:%M')} #{row.status.ljust(12)} #{row.dump_basename}")
    end
  end

  desc <<~DESC
    Abandons the run holding the guided-restore lock (same as "Abandon" on the progress page): the run becomes
    'cancelled', the queues it paused are resumed and the lock is released. The local DB is left as it is: load the
    safety snapshot (or another dump) with db:rebuild afterwards when the load was interrupted.

    Usage:
      > bin/rails db_restore:abandon database=<target database name>

  DESC
  task abandon: :environment do
    abort('The ops DB is not available (bin/rails ops:prepare).') unless Ops.available?

    run = DbRestore::Lock.current_run
    abort('No restore run holds the lock.') unless run
    abort("Type the target database: database=#{run.target_database}") unless ENV['database'].to_s == run.target_database.to_s

    DbRestore::Restorer.abandon!(run, via: 'rake')
    puts("- Run ##{run.id} abandoned, lock released.")
    puts("- Safety snapshot: #{DbRestore::TerminalCommand.rebuild(run.snapshot_path)}") if run.snapshot_path.present?
  end
end
