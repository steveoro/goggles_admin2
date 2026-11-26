# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Filters
  #
  # The Season board filters (state chip, "show unlinked", "show done") and their persistence in the cookie
  # +season_board_filters+ (a small JSON object), so that the sidebar link, the redirects after a POST (crawl, prepare,
  # hold, link, switch) and the links without filter params land on the last chosen chip.
  #
  # - A request carries an explicit choice when it has the marker param (<tt>filters=1</tt>, on every chip and toggle
  #   link of the board) or any filter param (a deep link such as <tt>?state=sql_pending</tt> from the dashboard):
  #   that choice wins and is stored.
  # - Otherwise the filters come from the cookie. Only known keys and values are read back (a state of
  #   SeasonBoard::Builder::STATES, true toggles); anything else (bad JSON, unknown keys or states, an oversized
  #   value) is ignored.
  #
  # == Usage
  #   filters = SeasonBoard::Filters.explicit?(params) ? SeasonBoard::Filters.from_params(params) : SeasonBoard::Filters.load(cookie)
  #   filters.state          # => 'sql_pending' or nil
  #   filters.to_cookie      # => '{"state":"sql_pending"}' (nil when nothing is filtered)
  #
  Filters = Data.define(:state, :show_unlinked, :show_done) do
    # Cookie name.
    def self.cookie_name = 'season_board_filters'

    # Marker param of an explicit choice (the "All" chip and the "hide" links carry no filter param of their own).
    def self.marker = 'filters'

    # Filter params (besides the marker).
    def self.keys = %w[state show_unlinked show_done]

    # Largest cookie value read back (a valid one is well below it).
    def self.max_bytes = 256

    # No filter: the default view (past rows already done and rows without a FIN link hidden).
    def self.none = new(state: nil, show_unlinked: false, show_done: false)

    # True when the request params carry an explicit choice (the marker or any filter param).
    def self.explicit?(params)
      ([marker] + keys).any? { |key| params.key?(key) }
    end

    # Filters from the request params (a present toggle param is on; an unknown state is ignored).
    def self.from_params(params)
      new(state: valid_state(params[:state] || params['state']),
          show_unlinked: (params[:show_unlinked] || params['show_unlinked']).present?,
          show_done: (params[:show_done] || params['show_done']).present?)
    end

    # Filters read back from the cookie value (JSON), or ::none when missing or invalid (also any bytes that are not
    # valid UTF-8, e.g. a hand-made '%FF': the value comes straight from the browser, so nothing here may raise).
    def self.load(raw)
      return none unless raw.is_a?(String)

      text = raw.dup.force_encoding(Encoding::UTF_8)
      return none if text.empty? || text.bytesize > max_bytes || !text.valid_encoding?

      data = JSON.parse(text)
      return none unless data.is_a?(Hash)

      new(state: valid_state(data['state']), show_unlinked: data['show_unlinked'] == true, show_done: data['show_done'] == true)
    rescue StandardError
      none
    end

    # The state when it is one of the board states (String), else nil.
    def self.valid_state(value)
      value.is_a?(String) || value.is_a?(Symbol) ? value.to_s.presence_in(Builder::STATES.map(&:to_s)) : nil
    end

    # True when nothing is filtered.
    def none?
      state.nil? && !show_unlinked && !show_done
    end

    # JSON value of the cookie, or nil when nothing is filtered (the cookie is then deleted).
    def to_cookie
      return nil if none?

      { 'state' => state, 'show_unlinked' => (true if show_unlinked), 'show_done' => (true if show_done) }.compact.to_json
    end
  end
end
