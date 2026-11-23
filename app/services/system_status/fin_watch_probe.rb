# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::FINWatchProbe
  #
  # FIN "Riepilogo Eventi" watcher (FedernuotoWatchJob), read inline from its local state file:
  # :warn with a pending (not yet acknowledged) change or when the last check failed, :ok after a
  # successful check, :unknown when it never ran. (Phase 05 adds the check age.)
  #
  class FINWatchProbe < Probe
    protected

    def evaluate
      state = FedernuotoWatch::StateStore.new.read
      last_checked = parse_time(state['last_checked'])
      change = state['change'].presence
      return pending_result(change, last_checked) if change.is_a?(Hash)

      if state['last_error'].present?
        result(:warn, detail: detail_text(:failed, error: state['last_error'].to_s.truncate(120)), checked_at: last_checked)
      elsif last_checked
        result(:ok, detail: detail_text(:ok, time: format_time(last_checked)), checked_at: last_checked)
      else
        result(:unknown, detail: detail_text(:never))
      end
    end

    private

    def pending_result(change, last_checked)
      detail = detail_text(:pending, time: format_time(parse_time(change['detected_at'])))
      action = { label: I18n.t('shell.status.actions.season_board'), path: url_helpers.season_board_path }
      result(:warn, detail:, checked_at: last_checked, action:)
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
