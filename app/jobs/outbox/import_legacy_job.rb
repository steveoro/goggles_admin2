# frozen_string_literal: true

module Outbox
  #
  # = Outbox::ImportLegacyJob
  #
  # One-time registration of the scripts that existed before the Outbox (Outbox::Reconciler in import mode):
  # - results.sent/** => legacy_sent (history);
  # - results.new/old-subseeded/** and redo/ => archived, note "pre-Outbox leftover" (never pushed);
  # - the rest of results.new/** => the usual rules (results.new/normalize/0002-normalize_coded_names.sql: held,
  #   not applied locally).
  # Registers rows only: no file is moved, renamed or changed. Simulate by default (nothing written).
  #
  # Run by 'rake outbox:import [simulate=0]' (inline); safe to re-run (already registered files are unchanged).
  #
  class ImportLegacyJob < ApplicationJob
    queue_as :outbox

    # Returns the Outbox::Reconciler::Report.
    def perform(simulate: true, data_root: nil)
      root = data_root.presence || Outbox.data_root
      report = Outbox::Reconciler.call(data_root: root, import: true, simulate:)
      return report if simulate || report.skipped

      Ops.safely { Ops::Setting.store!(Outbox::Reconciler::IMPORTED_AT_KEY, Time.current.iso8601) }
      Ops.record_event!(kind: 'outbox.imported', level: 'success', data: report.counts)
      report
    end
  end
end
