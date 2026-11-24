# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::CrawlerProbe
  #
  # State of the local crawler server (Node, port 7000), from local reads only:
  # - is it running? The process of the PID file written by CrawlerLauncher (tmp/pids/crawler.pid), or else the
  #   'system_status.crawler' snapshot (#refresh!, RefreshJob only, asks the crawler for its status over HTTP with
  #   short timeouts: it also sees a crawler started by hand with `npm start`);
  # - what is it doing? Its status file (crawler/crawler-status.json, written by crawler/server/utility.js),
  #   parsed with CrawlerClient::Status.
  #
  # Levels: :ok idle, or busy (progress i/n); :warn a run claims to be in progress with no update for
  # BUSY_STALE_AFTER, or the last run failed; :error not running (dead PID process, or the last HTTP check found
  # nothing), with the "Start crawler" button; :unknown no PID process and no recent check.
  #
  class CrawlerProbe < Probe
    # A run claiming to be in progress without any status update for this long is reported as stuck.
    BUSY_STALE_AFTER = 30.minutes

    class << self
      def mode
        :snapshot
      end

      # Crawler status file (override with config.x.crawler.status_path).
      def status_path
        Pathname.new(Rails.configuration.x.crawler.status_path.presence || Rails.root.join('crawler/crawler-status.json'))
      end

      # PID file written by CrawlerLauncher (override with config.x.crawler.pid_path).
      def pid_path
        Pathname.new(Rails.configuration.x.crawler.pid_path.presence || CrawlerLauncher::PID_PATH)
      end
    end

    # Reads the crawler status over HTTP and stores it. Returns the Ops::Snapshot or nil.
    def refresh!
      status = CrawlerClient.new(timeout: 2, open_timeout: 1).status
      payload = { 'reachable' => !status.nil? }
      payload.merge!(status.slice('status', 'detail', 'timestamp', 'progress', 'total')) if status.is_a?(Hash)
      Ops.safely do
        next unless Ops.available?

        Ops::Snapshot.write!(snapshot_key, payload, source: 'system_status')
      end
    end

    # :alive, :dead (PID file present, process gone) or :none (no usable PID file).
    def pid_state
      pid = Integer(self.class.pid_path.read.strip, exception: false) if self.class.pid_path.exist?
      return :none unless pid&.positive?

      Process.kill(0, pid)
      :alive
    rescue Errno::ESRCH
      :dead
    rescue Errno::EPERM
      :alive
    rescue SystemCallError, IOError
      :none
    end

    protected

    def evaluate
      pid = pid_state
      reachable = recent_reachability
      return running_result if pid == :alive || reachable == true

      checked_at = snapshot&.taken_at
      return result(:error, detail: detail_text(:off), checked_at:, action: start_action) if pid == :dead || reachable == false

      result(:unknown, detail: detail_text(:never), checked_at:, action: start_action)
    end

    private

    # true/false from a snapshot younger than STALE_AFTER; nil without a recent one.
    def recent_reachability
      return nil if snapshot.nil? || stale?(snapshot.taken_at)

      snapshot.payload.is_a?(Hash) ? snapshot.payload['reachable'] == true : nil
    end

    def running_result
      status = CrawlerClient::Status.from(read_status_file)
      return result(:ok, detail: detail_text(:running_unknown), checked_at: now) if status.nil?

      checked_at = status.timestamp || now
      return result(:ok, detail: detail_text(:idle), checked_at:) if status.idle? && !status.error?

      level, detail = busy_level_and_detail(status)
      result(level, detail:, checked_at:, action: pull_action)
    end

    # [level, detail] of a crawler not idle: failed, stuck or busy.
    def busy_level_and_detail(status)
      if status.error?
        [:warn, detail_text(:failed, detail: status.detail.to_s.truncate(120))]
      elsif status.stale?(now:, stale_after: BUSY_STALE_AFTER)
        [:warn, detail_text(:stuck, time: format_time(status.timestamp))]
      else
        [:ok, busy_text(status)]
      end
    end

    def busy_text(status)
      return detail_text(:busy_progress, status: status.status.truncate(60), progress: status.progress, total: status.total) if status.total.positive?

      detail_text(:running, status: status.status.truncate(60))
    end

    # Parsed status file Hash, or nil (missing or unreadable).
    def read_status_file
      path = self.class.status_path
      path.exist? ? JSON.parse(path.read) : nil
    rescue JSON::ParserError, SystemCallError, IOError
      nil
    end

    def pull_action
      action_for(:crawler, url_helpers.sources_crawler_path)
    end

    def start_action
      action_for(:start_crawler, url_helpers.sources_crawler_start_path, http_method: :post)
    end
  end
end
