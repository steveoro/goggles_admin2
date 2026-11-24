# frozen_string_literal: true

module Health
  #
  # = Health::SeasonScope
  #
  # Which seasons the data health report covers, and how (all season types):
  # - :current  => ongoing (begin_date <= today <= end_date), plus the Season board season
  #                (SeasonBoard::Builder.latest_season): every group, daily;
  # - :closed   => end_date before today: every group, weekly; seasons with zero meetings and zero badges are
  #                "no data" and are never run;
  # - :upcoming => begin_date after today: only the 'setup' group, daily.
  #
  # Reads only the local MySQL DB (three queries: seasons, meeting and badge counts per season).
  #
  # == Usage
  #   scope = Health::SeasonScope.new
  #   scope.entries                 # => [Entry(season_id:, description:, status:, ...), ...] newest first
  #   scope.entry(252).groups       # => ["meetings", "badges", "people", "results", "setup"]
  #
  class SeasonScope
    STATUSES = %i[current closed upcoming].freeze
    ALL_GROUPS = Ops::HealthRun::GROUPS
    UPCOMING_GROUPS = %w[setup].freeze

    # One season of the report.
    Entry = Data.define(:season_id, :description, :begin_date, :end_date, :status, :meetings_count, :badges_count) do
      def current? = status == :current
      def closed? = status == :closed
      def upcoming? = status == :upcoming

      # True for a closed season without meetings and badges (listed, never run).
      def no_data? = closed? && meetings_count.zero? && badges_count.zero?

      # Groups run for this season (empty for a "no data" season).
      def groups
        return [] if no_data?

        upcoming? ? UPCOMING_GROUPS : ALL_GROUPS
      end
    end

    attr_reader :today

    # == Params:
    # - today: reference date (default: Date.current);
    # - board_season_id: the Season board season ID (default: SeasonBoard::Builder.latest_season), always :current.
    def initialize(today: Date.current, board_season_id: :latest)
      @today = today
      @board_season_id = board_season_id
    end

    # All the seasons (Entry), most recent begin date first.
    def entries
      @entries ||= load_entries
    end

    # The Entry for a season ID (nil when unknown).
    def entry(season_id)
      entries_by_id[season_id.to_i]
    end

    def current = entries.select(&:current?)
    def closed = entries.select(&:closed?)
    def upcoming = entries.select(&:upcoming?)

    # Seasons that are run (with at least one group), most recent first.
    def runnable = entries.reject(&:no_data?)

    # Status (Symbol) of a season ID (nil when unknown).
    def status_for(season_id)
      entry(season_id)&.status
    end

    # Groups to run for a season ID (empty when unknown or "no data").
    def groups_for(season_id)
      entry(season_id)&.groups || []
    end

    def board_season_id
      return @board_season_id unless @board_season_id == :latest

      @board_season_id = SeasonBoard::Builder.latest_season&.id
    end

    private

    def entries_by_id
      @entries_by_id ||= entries.index_by(&:season_id)
    end

    def load_entries
      meetings = GogglesDb::Meeting.unscoped.group(:season_id).count
      badges = GogglesDb::Badge.unscoped.group(:season_id).count
      GogglesDb::Season.unscoped.order(begin_date: :desc, id: :desc)
                       .pluck(:id, :description, :begin_date, :end_date).map do |id, description, begin_date, end_date|
        Entry.new(season_id: id, description:, begin_date:, end_date:, status: status_of(id, begin_date, end_date),
                  meetings_count: meetings[id].to_i, badges_count: badges[id].to_i)
      end
    end

    def status_of(id, begin_date, end_date)
      return :current if id == board_season_id
      return :upcoming if begin_date.present? && begin_date > today
      return :closed if end_date.present? && end_date < today

      :current
    end
  end
end
