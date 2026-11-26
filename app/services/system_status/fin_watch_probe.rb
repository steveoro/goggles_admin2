# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::FINWatchProbe
  #
  # FIN "Riepilogo Eventi" watcher (FedernuotoWatchJob, hourly), read inline from its local state file.
  #
  # Levels: :error the last check failed ('last_error'), with "Check now"; :warn a pending (not yet acknowledged)
  # change whose alert is shown (0.10.103: FedernuotoWatch::Progress.alert_shown?, so not a change the automation found
  # nothing actionable in), linking to the Season board, or no check for longer than FRESH_FOR (the recurring job is not
  # running), with "Check now"; :ok checked less than FRESH_FOR ago; :unknown never checked, with "Check now".
  #
  class FINWatchProbe < Probe
    # The watcher runs every hour: a last check older than this means it is not running.
    FRESH_FOR = 75.minutes

    protected

    def evaluate
      state = FedernuotoWatch::StateStore.new.read
      last_checked = parse_time(state['last_checked'])
      return failed_result(state['last_error'], last_checked) if state['last_error'].present?

      change = state['change'].presence
      return pending_result(change, last_checked) if change.is_a?(Hash) && alert_shown?(change, state)
      return result(:unknown, detail: detail_text(:never), action: check_action) unless last_checked
      return result(:ok, detail: detail_text(:ok, time: format_time(last_checked)), checked_at: last_checked) if last_checked >= now - FRESH_FOR

      result(:warn, detail: detail_text(:stale, time: format_time(last_checked)), checked_at: last_checked, action: check_action)
    end

    private

    def alert_shown?(change, state)
      FedernuotoWatch::Progress.alert_shown?(change, FedernuotoWatch::Progress.read(state['digest']))
    end

    def failed_result(error, last_checked)
      result(:error, detail: detail_text(:failed, error: error.to_s.truncate(120)), checked_at: last_checked, action: check_action)
    end

    def pending_result(change, last_checked)
      detail = detail_text(:pending, time: format_time(parse_time(change['detected_at'])))
      result(:warn, detail:, checked_at: last_checked, action: action_for(:season_board, url_helpers.season_board_path))
    end

    def check_action
      action_for(:check_fin, url_helpers.federnuoto_watch_check_path, http_method: :post)
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
