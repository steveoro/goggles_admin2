# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::OpsDbProbe
  #
  # The local ops DB (event log, settings, snapshots: see Ops::Database), read inline.
  #
  # Levels: :ok ready; :error not configured, missing or not migrated ("run bin/rails ops:prepare"): the dashboard
  # counters, the board summary, the event log and every snapshot-based status are unavailable meanwhile.
  #
  class OpsDbProbe < Probe
    protected

    def evaluate
      state = Ops.state
      return result(:ok, detail: detail_text(:ok), checked_at: now) if state == :ready

      result(:error, detail: detail_text(:not_ready, state: I18n.t("ops.setup_notice.states.#{state}", default: state.to_s)), checked_at: now)
    end
  end
end
