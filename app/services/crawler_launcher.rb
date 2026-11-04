# frozen_string_literal: true

require 'fileutils'

#
# = CrawlerLauncher
#
# Checks whether the local crawler server (Node, see crawler/) is up and, if not, spawns it
# with `npm start` in the background so that a crawl can be started right away from the UI.
#
# The process is spawned in its own process group, so it survives a restart (or Ctrl-C) of
# the Rails server; its output goes to log/crawler.log and its PID to tmp/pids/crawler.pid.
#
class CrawlerLauncher
  STATUS_URL = "#{PullController::CRAWLER_API_URL}status".freeze
  CRAWLER_DIR = Rails.root.join('crawler')
  LOG_PATH = Rails.root.join('log/crawler.log')
  PID_PATH = Rails.root.join('tmp/pids/crawler.pid')

  # == Params:
  # - npm_bin: npm executable (default: ENV['CRAWLER_NPM'] or 'npm' from the PATH);
  # - wait_for: max seconds to wait for the server to answer after spawning it.
  def initialize(npm_bin: ENV.fetch('CRAWLER_NPM', 'npm'), wait_for: 10)
    @npm_bin = npm_bin
    @wait_for = wait_for
  end

  # Returns true if the crawler server answers to its status endpoint.
  def running?
    RestClient::Request.execute(method: :get, url: STATUS_URL, timeout: 2, open_timeout: 2)
    true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, RestClient::Exception
    false
  end

  # Starts the crawler server unless it's already running.
  # Returns :already_running, :started or :failed.
  def ensure_running!
    return :already_running if running?

    spawn_server
    wait_until_running ? :started : :failed
  rescue SystemCallError => e
    Rails.logger.error("[CrawlerLauncher] spawn failed: #{e.class}: #{e.message}")
    :failed
  end

  # Returns the [flash_symbol, message] pair describing an #ensure_running! result.
  def self.flash_for(launch_result)
    case launch_result
    when :started
      [:info, I18n.t('federnuoto_watch.crawler.started')]
    when :already_running
      [:notice, I18n.t('federnuoto_watch.crawler.already_running')]
    else
      [:error, I18n.t('federnuoto_watch.crawler.failed', log: LOG_PATH.relative_path_from(Rails.root))]
    end
  end

  private

  def spawn_server
    FileUtils.mkdir_p([LOG_PATH.dirname, PID_PATH.dirname])
    # (The child gets its own copy of the log descriptor, so it's safe to close ours right after spawning)
    pid = File.open(LOG_PATH, 'a') do |log|
      Process.spawn(@npm_bin, 'start', chdir: CRAWLER_DIR.to_s, out: log, err: log, in: File::NULL, pgroup: true)
    end
    Process.detach(pid)
    File.write(PID_PATH, pid.to_s)
    Rails.logger.info("[CrawlerLauncher] spawned '#{@npm_bin} start' (PID #{pid}), logging to #{LOG_PATH}")
  end

  def wait_until_running
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait_for
    loop do
      return true if running?
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep(0.5)
    end
  end
end
