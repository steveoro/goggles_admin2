# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::CrawlerProbe
  #
  # State of the local crawler server (Node, port 7000), from the 'system_status.crawler' snapshot.
  # #refresh! (RefreshJob only) asks the crawler for its status with short timeouts.
  #
  # The crawler is started on demand (Pull page / Season board), so "not running" is not an error:
  # it's reported as :unknown ("off").
  #
  class CrawlerProbe < Probe
    def self.mode
      :snapshot
    end

    # Reads the crawler status and stores it. Returns the Ops::Snapshot or nil.
    def refresh!
      status = CrawlerClient.new(timeout: 2, open_timeout: 1).status
      payload = { 'reachable' => !status.nil? }
      payload.merge!(status.slice('status', 'detail', 'timestamp', 'progress', 'total')) if status.is_a?(Hash)
      Ops.safely do
        next unless Ops.available?

        Ops::Snapshot.write!(snapshot_key, payload, source: 'system_status')
      end
    end

    protected

    def evaluate
      return result(:unknown, detail: detail_text(:never), action: pull_action) if snapshot.nil?

      payload = snapshot.payload.is_a?(Hash) ? snapshot.payload : {}
      checked_at = snapshot.taken_at
      return result(:unknown, detail: detail_text(:stale, time: format_time(checked_at)), checked_at:) if stale?(checked_at)
      return result(:unknown, detail: detail_text(:off), checked_at:, action: pull_action) unless payload['reachable']

      running_result(CrawlerClient::Status.from(payload), checked_at)
    end

    private

    def running_result(status, checked_at)
      return result(:ok, detail: detail_text(:idle), checked_at:) if status.idle? && !status.error?

      if status.error?
        result(:warn, detail: detail_text(:failed, detail: status.detail.truncate(120)), checked_at:, action: pull_action)
      else
        result(:ok, detail: detail_text(:running, status: status.status.truncate(60)), checked_at:, action: pull_action)
      end
    end

    def pull_action
      { label: I18n.t('shell.status.actions.crawler'), path: url_helpers.pull_index_path }
    end
  end
end
