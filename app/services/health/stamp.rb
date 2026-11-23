# frozen_string_literal: true

module Health
  #
  # = Health::Stamp
  #
  # Cheap digest of a season's data, compared with the stamp of the last succeeded run of a heavy group to skip
  # an unchanged closed season (Health::Runner with <tt>skip_unchanged: true</tt>, used by Health::SweepJob).
  #
  # Facts (local MySQL DB, one aggregate query each, plus one directory stat):
  # - meetings and badges of the season: count, max id, max updated_at;
  # - calendars of the season: count, max updated_at;
  # - MIRs and MRRs of the season: count, max updated_at;
  # - mtime of crawler/data/results.new/<season>;
  # - Ops::Setting.db_epoch (a restored local DB always re-runs).
  #
  class Stamp
    attr_reader :season_id

    def initialize(season_id:, data_dir: SeasonBoard::DiskIndex.default_data_dir)
      @season_id = season_id.to_i
      @data_dir = Pathname.new(data_dir)
    end

    # SHA256 hex of the facts.
    def digest
      @digest ||= Digest::SHA256.hexdigest(JSON.generate(facts))
    end

    # The facts (Hash of String => Array/String/Integer).
    def facts
      @facts ||= {
        'meetings' => aggregate(GogglesDb::Meeting.unscoped.where(season_id:), with_id: true),
        'badges' => aggregate(GogglesDb::Badge.unscoped.where(season_id:), with_id: true),
        'calendars' => aggregate(GogglesDb::Calendar.unscoped.where(season_id:)),
        'mirs' => aggregate(results_scope(GogglesDb::MeetingIndividualResult)),
        'mrrs' => aggregate(results_scope(GogglesDb::MeetingRelayResult)),
        'results_new_mtime' => dir_mtime,
        'db_epoch' => Ops.safely(1) { Ops::Setting.db_epoch }
      }
    end

    private

    def aggregate(scope, with_id: false)
      table = scope.klass.table_name
      columns = ["COUNT(#{table}.id)", "MAX(#{table}.updated_at)"]
      columns << "MAX(#{table}.id)" if with_id
      Array(scope.pick(*columns.map { |col| Arel.sql(col) })).map { |value| value.respond_to?(:iso8601) ? value.utc.iso8601(6) : value }
    end

    def results_scope(klass)
      klass.unscoped.joins(meeting_program: { meeting_event: :meeting_session })
           .joins('INNER JOIN meetings ON meetings.id = meeting_sessions.meeting_id')
           .where(meetings: { season_id: })
    end

    def dir_mtime
      dir = @data_dir.join('results.new', season_id.to_s)
      dir.directory? ? dir.mtime.utc.iso8601(6) : nil
    end
  end
end
