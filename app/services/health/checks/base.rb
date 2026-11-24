# frozen_string_literal: true

module Health
  module Checks
    #
    # = Health::Checks::Base
    #
    # Parent of the group check classes (one per Ops::HealthRun::GROUPS entry, see Health::Registry::GROUP_CLASSES).
    # A group class runs every check of its group for one season and returns their findings.
    #
    # Checks are READ-ONLY on the primary DB (a spec asserts no INSERT/UPDATE/DELETE during a run): they only read
    # MySQL rows (Meeting/Calendar always +unscoped+: their default scopes eager-load associations) and local files.
    #
    # == Subclass interface
    # - #call => Array of Health::Finding.
    #
    class Base
      # Days after the header date before a current-season meeting without results is reported.
      RECENT_DAYS = 14

      attr_reader :season, :entry, :today, :data_dir

      # == Params:
      # - season: GogglesDb::Season;
      # - entry: its Health::SeasonScope::Entry (status :closed, :current or :upcoming);
      # - today: reference date; data_dir: crawler data folder (default: SeasonBoard::DiskIndex.default_data_dir).
      def initialize(season:, entry:, today: Date.current, data_dir: nil)
        @season = season
        @entry = entry
        @today = today
        @data_dir = Pathname.new(data_dir || SeasonBoard::DiskIndex.default_data_dir)
      end

      def call
        raise NotImplementedError, "#{self.class.name}#call"
      end

      protected

      def closed? = entry.closed?
      def current? = entry.current?
      def season_id = season.id

      # Builds a Health::Finding.
      def finding(check_key, **attributes)
        Health::Finding.new(check_key:, **attributes)
      end

      # Sorted, comma-separated ids ('12,34').
      def id_list(ids)
        Array(ids).map(&:to_i).uniq.sort.join(',')
      end

      def bool(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      def to_date(value)
        return value if value.is_a?(Date)
        return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

        Date.iso8601(value.to_s)
      rescue ArgumentError # (Date::Error included)
        nil
      end
    end
  end
end
