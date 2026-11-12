# frozen_string_literal: true

require 'base64'
require 'cgi'

# = FINEventId
#
# Extracts the numeric FIN (federnuoto.it) event ID from the URLs collected by the
# crawler. The same ID identifies a meeting both in its results page URL and in its
# manifest download URL, so it's a stable key for linking a FIN calendar row to the
# local Calendar/Meeting rows (stored in <tt>calendars.results_code</tt>).
#
# == Supported URL formats
# - Results page:
#   ".../eventi-circuito-supermaster.html#/risultati/150091:distanze-speciali-campania-2026.html"
# - Manifest download:
#   ".../component/solrconnect/download.html?file=<Base64 of '/var/www/fin_files/eventi/0000150091.pdf'>"
#
# All methods return the ID as a String without leading zeros (e.g. "150091"),
# or +nil+ when the URL is blank or doesn't carry a FIN event ID.
#
module FINEventId
  RESULTS_URL_REGEXP = %r{risultati/0*(\d+):}
  MANIFEST_PATH_REGEXP = %r{/eventi/0*(\d+)\.pdf\z}i
  FIN_HOST_REGEXP = %r{\Ahttps?://(www\.)?federnuoto\.it/}i

  module_function

  # Returns the FIN event ID found in a results page URL, or +nil+.
  def from_results_url(url)
    return nil if url.blank?

    url.to_s[RESULTS_URL_REGEXP, 1]
  end

  # Returns the FIN event ID found in a manifest download URL, or +nil+.
  def from_manifest_url(url)
    return nil if url.blank?

    encoded = url.to_s[/[?&]file=([^&#]+)/, 1]
    return nil if encoded.blank?

    decoded = Base64.decode64(CGI.unescape(encoded)).force_encoding(Encoding::UTF_8)
    return nil unless decoded.valid_encoding?

    decoded[MANIFEST_PATH_REGEXP, 1]
  end

  # Returns the FIN event ID from either kind of URL, or +nil+.
  def parse(url)
    from_results_url(url) || from_manifest_url(url)
  end

  # Returns the first FIN event ID found among the given URLs, or +nil+.
  def parse_any(*urls)
    urls.flatten.each do |url|
      id = parse(url)
      return id if id
    end
    nil
  end

  # True when the URL points to the FIN website (regardless of it carrying an event ID).
  def fin_url?(url)
    url.to_s.strip.match?(FIN_HOST_REGEXP)
  end
end
