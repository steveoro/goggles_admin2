# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module FedernuotoWatch
  #
  # = FedernuotoWatch::Fetcher
  #
  # Retrieves the rendered DOM of the watched page by running headless Chrome with '--dump-dom'
  # (the FIN site answers with a 503 to plain HTTP clients).
  #
  # Each run uses a throw-away Chrome profile so that it never interferes with a running browser.
  # The command is wrapped by coreutils' `timeout` to guarantee termination.
  #
  class Fetcher
    CHROME_FLAGS = %w[
      --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage
      --virtual-time-budget=20000 --dump-dom
    ].freeze

    # == Params:
    # - url: target page URL;
    # - chrome_bin: path to the Chrome executable (default: ENV['CHROME_BIN'] or '/usr/bin/google-chrome');
    # - timeout: max seconds allowed for each Chrome run;
    # - tries: total number of attempts;
    # - retry_delay: seconds to wait between attempts.
    def initialize(url: FedernuotoWatch::URL, chrome_bin: ENV.fetch('CHROME_BIN', '/usr/bin/google-chrome'),
                   timeout: 90, tries: 3, retry_delay: 2)
      @url = url
      @chrome_bin = chrome_bin
      @timeout = timeout
      @tries = tries
      @retry_delay = retry_delay
    end

    # Returns the page HTML as a String.
    # Raises FedernuotoWatch::FetchError when all attempts fail.
    def call
      raise FetchError, "Chrome executable not found at '#{@chrome_bin}' (set CHROME_BIN)" unless File.executable?(@chrome_bin)

      last_error = nil
      @tries.times do |attempt|
        html, last_error = dump_dom
        return html if html

        Rails.logger.warn("[FedernuotoWatch::Fetcher] attempt #{attempt + 1}/#{@tries} failed: #{last_error}")
        sleep(@retry_delay) if attempt < @tries - 1
      end
      raise FetchError, "Failed to fetch #{@url} after #{@tries} attempts (#{last_error})"
    end

    private

    # Runs Chrome once; returns [html, nil] on success or [nil, error_description] otherwise.
    def dump_dom
      Dir.mktmpdir('fin-watch-chrome') do |profile_dir|
        out, err, status = Open3.capture3(
          'timeout', @timeout.to_s, @chrome_bin, *CHROME_FLAGS, "--user-data-dir=#{profile_dir}", '--', @url
        )
        return [out, nil] if status.success? && out.include?('<')

        [nil, "exit=#{status.exitstatus} out_len=#{out.length} err=#{err.to_s.strip.lines.last(2).join(' ').strip}"]
      end
    rescue SystemCallError => e
      [nil, "#{e.class}: #{e.message}"]
    end
  end
end
