# frozen_string_literal: true

# = TeamManagerSqlCreate
#
#   - author:   Steve A.
#
# Creates a GogglesDb::ManagedAffiliation row (linking a User "manager" to a TeamAffiliation)
# on the *localhost* DB, generating at the same time a replayable single-transaction SQL
# batch file that can be pushed to the remote production server.
#
# When the specified team has no affiliation for the chosen season yet, the missing
# TeamAffiliation row is created too (inside the same transaction & batch file), inheriting
# name/number/compute_gogglecup defaults from the team's most recent previous affiliation,
# when available.
#
# The localhost DB is assumed to be in-sync with production: the SQL INSERTs keep the
# explicit local IDs (SqlMaker force_id_on_insert default), so the batch replay on the
# remote server will recreate the very same rows.
#
# === Typical usage:
#   creator = TeamManagerSqlCreate.new(season_id: ..., team_id: ..., user_id: ...)
#   if creator.call
#     creator.file_path # => pathname of the generated .sql batch (under crawler/data/results.new/<season_id>/)
#     creator.script    # => its Ops::SqlScript (Outbox registry; kind 'team_manager')
#   else
#     creator.errors    # => array of error messages
#   end
#
class TeamManagerSqlCreate
  attr_reader :sql_log, :errors, :file_path, :script, :data_root,
              :season, :team, :user, :affiliation, :managed_affiliation

  # Creates a new instance, resolving the given IDs against the localhost DB.
  #
  # == Params
  # - <tt>season_id</tt>, <tt>team_id</tt>, <tt>user_id</tt>: row IDs for the tuple to be created
  # - <tt>data_root</tt>: crawler data root (default: 'crawler/data')
  #
  def initialize(season_id:, team_id:, user_id:, data_root: Outbox.data_root)
    @season_id = season_id
    @team_id = team_id
    @user_id = user_id
    @season = GogglesDb::Season.find_by(id: season_id)
    @team = GogglesDb::Team.find_by(id: team_id)
    @user = GogglesDb::User.find_by(id: user_id)
    @data_root = Pathname.new(data_root)
    @sql_log = []
    @errors = []
  end
  #-- -------------------------------------------------------------------------
  #++

  # Runs the feasibility checks, performs the local DB creation(s) inside a single
  # transaction while logging the equivalent SQL statements, then writes the resulting
  # batch file under <tt>crawler/data/results.new/<season_id>/</tt>.
  #
  # == Returns
  # +true+ when the rows were created locally and the SQL file was written;
  # +false+ otherwise (check #errors).
  #
  def call
    return false unless entities_present?
    return false if managed_affiliation_exists?

    @sql_log << '-- Team Manager (managed_affiliations) creation: ' \
                "season_id=#{@season.id}, team_id=#{@team.id}, user_id=#{@user.id}\r\n"
    @sql_log << 'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
    @sql_log << 'SET AUTOCOMMIT = 0;'
    @sql_log << 'START TRANSACTION;'
    @sql_log << "--\r\n"

    ActiveRecord::Base.transaction do
      create_affiliation_if_missing
      create_managed_affiliation
      @sql_log << "\r\n--\r\n"
      @sql_log << 'COMMIT;'
      # File write inside the transaction block: on failure the whole creation rolls
      # back, so no batch file will ever exist without its corresponding local rows.
      write_sql_file
    end

    true
  rescue StandardError => e
    # (the local rows rolled back: a script written meanwhile must not stay pushable)
    Outbox::Writer.discard!(@script)
    @script = nil
    @file_path = nil
    @errors << e.message
    false
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Collects an error for each missing entity; returns true when all 3 exist.
  def entities_present?
    @errors << I18n.t('datagrid.sql_create.missing_entity', entity: 'Season', id: @season_id) unless @season
    @errors << I18n.t('datagrid.sql_create.missing_entity', entity: 'Team', id: @team_id) unless @team
    @errors << I18n.t('datagrid.sql_create.missing_entity', entity: 'User', id: @user_id) unless @user
    @errors.empty?
  end

  # Sets @affiliation & returns true when a ManagedAffiliation already exists for the
  # resolved (season, team) affiliation and user (adding also a localized error message).
  def managed_affiliation_exists?
    @affiliation = GogglesDb::TeamAffiliation.find_by(season_id: @season.id, team_id: @team.id)
    return false unless @affiliation &&
                        GogglesDb::ManagedAffiliation.exists?(team_affiliation_id: @affiliation.id, user_id: @user.id)

    @errors << I18n.t('datagrid.sql_create.duplicate_error',
                      ta_id: @affiliation.id, user_id: @user.id)
    true
  end

  # Creates the missing TeamAffiliation row, inheriting name/number/compute_gogglecup
  # from the team's affiliation for the latest previous season, when available.
  def create_affiliation_if_missing
    return if @affiliation

    previous = GogglesDb::TeamAffiliation.where(team_id: @team.id)
                                         .order(season_id: :desc)
                                         .first
    @affiliation = GogglesDb::TeamAffiliation.create!(
      season: @season, team: @team,
      name: previous&.name.presence || @team.name,
      number: previous&.number.presence || '?',
      compute_gogglecup: previous&.compute_gogglecup || false,
      autofilled: true
    )
    @sql_log << SqlMaker.new(row: @affiliation).log_insert
  end

  # Creates the ManagedAffiliation row linking the user to the affiliation.
  def create_managed_affiliation
    @managed_affiliation = GogglesDb::ManagedAffiliation.create!(
      team_affiliation: @affiliation, manager: @user
    )
    @sql_log << SqlMaker.new(row: @managed_affiliation).log_insert
  end

  # Registers the collected SQL log as a new Outbox script inside
  # '<data_root>/results.new/<season_id>/' (pushed from the Outbox page).
  def write_sql_file
    @script = Outbox::Writer.write!(
      kind: 'team_manager', name: "team_manager-#{@affiliation.id}-#{@managed_affiliation.id}",
      sql: "#{@sql_log.join("\r\n")}\r\n", folder: @season.id.to_s, season_id: @season.id, data_root:,
      origin: { 'producer' => 'team_manager', 'team_affiliation_id' => @affiliation.id,
                'managed_affiliation_id' => @managed_affiliation.id, 'user_id' => @user.id }
    )
    @file_path = @script.absolute_path
  end
end
