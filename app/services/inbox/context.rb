# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Context
  #
  # What every Inbox::Source receives in #items(context) (built once per "Needs you" render):
  # - season: the Season board season (GogglesDb::Season, the latest MASFIN one), or nil;
  # - board_snapshot: the SeasonBoard::Snapshot::Summary of +season+ (nil without a season). Lazy: fetched
  #   (SeasonBoard::Snapshot.fetch: the stored summary while fresh, else a local board build) on first use
  #   only, and once; a failed fetch raises again for every source asking for it;
  # - now: reference Time; api_offline: true in an API-offline session; ops_available: Ops.available?;
  # - user: the signed-in GogglesDb::User (or nil);
  # - api_url: the configured API base URL (no trailing slash);
  # - data_dir: the crawler data folder (default: SeasonBoard::DiskIndex.default_data_dir).
  #
  # Every reader is local (session, local DB, local files, ops DB): building a context never calls the network.
  #
  class Context
    attr_reader :season, :now, :api_offline, :ops_available, :user, :api_url, :data_dir

    # rubocop:disable Metrics/ParameterLists
    # == Params (all optional):
    # - board_snapshot: a Summary (or nil) to use instead of fetching it (e.g. in specs);
    # - season: default SeasonBoard::Builder.latest_season (only when +board_snapshot+ is not given).
    def initialize(season: :latest, board_snapshot: :fetch, now: Time.current, api_offline: false, ops_available: nil,
                   user: nil, api_url: nil, data_dir: nil)
      @season = if season == :latest
                  board_snapshot == :fetch ? SeasonBoard::Builder.latest_season : nil
                else
                  season
                end
      @board_snapshot = board_snapshot
      @now = now
      @api_offline = api_offline
      @ops_available = ops_available.nil? ? Ops.available? : ops_available
      @user = user
      @api_url = (api_url || Shell::APITarget.configured_url).to_s.delete_suffix('/')
      @data_dir = Pathname.new(data_dir || SeasonBoard::DiskIndex.default_data_dir)
    end
    # rubocop:enable Metrics/ParameterLists

    def api_offline? = api_offline
    def ops_available? = ops_available

    # The board Summary of the season (fetched once, see the class notes), or nil without a season.
    def board_snapshot
      raise @board_error if @board_error
      return @board_snapshot unless @board_snapshot == :fetch

      @board_snapshot = season && SeasonBoard::Snapshot.fetch(season)
    rescue StandardError => e
      @board_error = e
      raise
    end
  end
end
