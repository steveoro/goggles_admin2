# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::InspectJob
  #
  # Wizard step 3: inspects the chosen dump of an 'inspecting' Ops::RestoreRun (DbRestore::DumpInspector: read-only,
  # streams the bz2 once) and stores the results on the run: 'ready' when the dump can be restored, 'failed' with
  # the reasons otherwise. Enqueued only by DbRestoreController#create; no retries; never raises.
  #
  class InspectJob < ApplicationJob
    queue_as :maintenance

    def perform(run_id:)
      run = Ops.safely { Ops::RestoreRun.find_by(id: run_id) }
      return unless run&.inspecting?

      run.update!(job_id:, step: 'inspect')
      result = DbRestore::DumpInspector.call(run.dump_path)
      store(run, result)
    rescue StandardError => e
      Rails.logger.error("[DbRestore::InspectJob] run #{run_id}: #{e.class}: #{e.message}")
      Ops.safely { run&.update!(status: 'failed', error_text: "#{e.class}: #{e.message}", finished_at: Time.current) }
    end

    private

    def store(run, result)
      run.update!(
        status: result.ok? ? 'ready' : 'failed', step: result.ok? ? 'inspected' : 'inspect_failed',
        dump_bytes: result.bytes, dump_sha256: result.sha256, dump_taken_at: result.taken_at,
        dump_schema_version: result.schema_version, dump_tables: result.tables, dump_iq_next_id: result.iq_next_id,
        inspection: result.details, error_text: result.ok? ? nil : error_text(result), finished_at: result.ok? ? nil : Time.current
      )
      run.append_log!(I18n.t(result.ok? ? 'db_restore.log.inspected' : 'db_restore.log.inspect_failed', count: result.tables.size))
    end

    def error_text(result)
      result.errors.map { |error| I18n.t("db_restore.inspection.errors.#{error['code']}", detail: error['detail'].to_s) }.join(' • ')
    end
  end
end
