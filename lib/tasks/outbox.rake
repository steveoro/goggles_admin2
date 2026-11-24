# frozen_string_literal: true

#
# = SQL Outbox tasks (see Outbox, docs/outbox.md)
#
#   - for Goggles framework vers.: 7+
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

namespace :outbox do
  desc <<~DESC
    One-time registration of the SQL scripts written before the Outbox (rows only: no file is moved or changed).

    - crawler/data/results.sent/**               => legacy_sent (history)
    - crawler/data/results.new/old-subseeded/**  => archived ("pre-Outbox leftover", never pushed)
    - crawler/data/redo/                         => archived
    - the rest of crawler/data/results.new/**    => pending (normalize & standard timings: held, not applied locally)

    Never scans results.done*, results.backup, results.old. Safe to re-run.

    Options: [simulate=0|<1>]   (default: simulate, nothing written)

    Usage:
      > bin/rails outbox:import             # dry run: prints the counts
      > bin/rails outbox:import simulate=0  # registers the rows

  DESC
  task import: :environment do
    simulate = ENV['simulate'] != '0'
    report = Outbox::ImportLegacyJob.perform_now(simulate:)
    puts(report.lines)
    puts("\r\n\t\t>>> NOTHING WAS WRITTEN: THIS WAS JUST A SIMULATION (use simulate=0 to register) <<<") if simulate
  end

  desc <<~DESC
    Converges the Outbox registry with the files under crawler/data/results.new/**, results.sent/** and redo/
    (adopts unknown files, follows moves, marks missing files). Prints what changed.

    Usage:
      > bin/rails outbox:reconcile

  DESC
  task reconcile: :environment do
    report = Outbox::Reconciler.call
    puts(report.lines)
    report.changes.each { |action, rel_path| puts("  - #{action}: #{rel_path}") unless action == 'restat' }
  end

  desc <<~DESC
    Shows the Outbox counters: scripts per state, the next script to push and the last push runs.

    Usage:
      > bin/rails outbox:status

  DESC
  task status: :environment do
    abort("The 'ops' DB is #{Ops.state}: run 'bin/rails ops:prepare' first.") unless Ops.available?

    Ops::SqlScript.group(:state).count.sort.each { |state, count| puts(format('%-20<state>s %<count>5d', state:, count:)) }
    next_script = Ops::SqlScript.pending.ordered.first
    puts("Next to push: #{next_script ? "#{next_script.seq} #{next_script.rel_path}" : '-'}")
    puts("Sequence....: #{Outbox::Sequence.current_max}")
    puts("Imported....: #{Ops::Setting.fetch(Outbox::Reconciler::IMPORTED_AT_KEY) || 'not yet (rake outbox:import)'}")
    Ops::PushRun.recent.limit(5).each do |run|
      puts("Run #{run.id}: #{run.status}, #{run.pushed_count}/#{run.total} pushed, #{run.started_at} -> #{run.target_api_url}")
    end
  end
end
