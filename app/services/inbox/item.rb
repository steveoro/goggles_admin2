# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Item
  #
  # One entry of the dashboard "Needs you" list, emitted by an Inbox::Source:
  # - key: stable String (e.g. 'board:1234:crawl'); Inbox::Builder keeps one item per key;
  # - source: Symbol key of the emitting source; kind: Symbol (e.g. :crawl, :job_failed);
  # - band: one of BANDS (Symbol, or its Integer rank), the priority group;
  # - title, detail: translated texts (detail optional);
  # - subject: Hash describing what the item is about, e.g. { fin_event_id:, file_path:, season_id: }
  #   (+file_path+ also de-duplicates items about the same source file, see Inbox::Builder);
  # - action: the Inbox::Action (required: exactly one primary action per item);
  # - since: Time the matter has been waiting since (oldest first within a band; default: now);
  # - count: Integer, for grouped items (default 1);
  # - secondary_action: optional second Inbox::Action, shown as a small link next to the button (e.g. "Retry" next
  #   to "Discard" for a failed job). Never required.
  #
  class Item < Data.define(:key, :source, :kind, :band, :title, :detail, :subject, :action, :since, :count, :secondary_action)
    # Priority bands, lower first:
    # - blocked: cannot work at all (API offline, background JWT expired, ops DB missing, no job process);
    # - failed: failed or stuck jobs; push: scripts waiting to be pushed (order matters);
    # - review: Data-Fix reviews (in review, results ready, structure ready, header review);
    # - acquire: extract a manifest, check results, crawl, link a calendar;
    # - notice: FIN calendar change, drift warning, idle sessions.
    BANDS = { blocked: 0, failed: 1, push: 2, review: 3, acquire: 4, notice: 5 }.freeze

    # rubocop:disable-next Metrics/ParameterLists
    def initialize(key:, source:, kind:, band:, title:, action:, detail: nil, subject: {}, since: nil, count: 1, secondary_action: nil)
      raise ArgumentError, 'an inbox item needs an Inbox::Action' unless action.is_a?(Inbox::Action)
      raise ArgumentError, 'secondary_action must be an Inbox::Action' unless secondary_action.nil? || secondary_action.is_a?(Inbox::Action)
      raise ArgumentError, 'an inbox item needs a key and a title' if key.blank? || title.blank?

      super(key: key.to_s, source: source.to_sym, kind: kind.to_sym, band: normalize_band(band), title: title.to_s,
            detail: detail.presence, subject: (subject || {}).to_h, action:, since: since || Time.current,
            count: [count.to_i, 1].max, secondary_action:)
    end

    # Integer rank of the band (lower first).
    def band_rank = BANDS.fetch(band)

    # Sort key used by Inbox::Builder: band, then oldest first.
    def sort_key = [band_rank, since.to_f, key]

    private

    def normalize_band(band)
      symbol = band.is_a?(Integer) ? BANDS.key(band) : band&.to_sym
      raise ArgumentError, "unsupported band: #{band.inspect}" unless BANDS.key?(symbol)

      symbol
    end
  end
end
