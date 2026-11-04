# frozen_string_literal: true

#
# = FedernuotoWatch
#
# Watches the FIN "Riepilogo Eventi" page (Supermaster calendar summary) for changes and
# notifies any open page of the app (see FedernuotoWatchJob, scheduled in config/recurring.yml).
#
# Main pieces:
# - Fetcher:   dumps the page DOM using headless Chrome (plain HTTP gets a 503 from the site);
# - Extractor: extracts a normalized snapshot (meeting rows + text digest) of 'main section#component';
# - StateStore: JSON file persisting the last snapshot, the acknowledged snapshot & any pending change;
# - Checker:   orchestrates the above, computing the diff between the acknowledged & latest snapshot;
# - Notifier:  live-broadcasts alerts to all connected browsers through AppNotificationsChannel.
#
module FedernuotoWatch
  # Watched page:
  URL = 'https://www.federnuoto.it/home/master/circuito-supermaster/riepilogo-eventi.html'

  # Base for relative links found on the page:
  BASE_URL = 'https://www.federnuoto.it'

  # DOM ID for the (sticky) change alert & for the transient (info/error) check alert:
  ALERT_DOM_ID = 'federnuoto-watch-alert'
  INFO_DOM_ID = 'federnuoto-watch-info'

  # Generic watcher error
  class Error < StandardError; end

  # Raised when the page can't be retrieved
  class FetchError < Error; end

  # Raised when the page doesn't include the expected section
  class ParseError < Error; end

  # Returns the given ISO8601 timestamp as a local (system time zone) Time, or nil if blank/invalid.
  # (The app runs only on localhost and uses UTC as its default zone, so the system zone is the user's.)
  def self.local_time(iso_time)
    Time.zone.parse(iso_time.to_s)&.localtime
  rescue ArgumentError
    nil
  end
end
