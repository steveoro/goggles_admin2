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
#   else
#     creator.errors    # => array of error messages
#   end
#
class TeamManagerSqlCreate
  include FileCounter

  attr_reader :sql_log, :errors, :file_path,
              :season, :team, :user, :affiliation, :managed_affiliation

  # Creates a new instance, resolving the given IDs against the localhost DB.
  #
  # == Params
  # - <tt>season_id</tt>, <tt>team_id</tt>, <tt>user_id</tt>: row IDs for the tuple to be created
  #
  def initialize(season_id:, team_id:, user_id:)
    @season_id = season_id
    @team_id = team_id
    @user_id = user_id
    @season = GogglesDb::Season.find_by(id: season_id)
    @team = GogglesDb::Team.find_by(id: team_id)
    @user = GogglesDb::User.find_by(id: user_id)
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

  # Writes the collected SQL log into a new sequential batch file inside
  # 'crawler/data/results.new/<season_id>/' (for the push dashboard & upload pipeline).
  def write_sql_file
    source_dir = Rails.root.join("crawler/data/results.new/#{@season.id}")
    sent_dir = source_dir.to_s.gsub('results.new', 'results.sent')
    FileUtils.mkdir_p(source_dir)

    counter = compute_file_counter(source_dir, sent_dir)
    file_name = "#{format('%04d', counter + 1)}-team_manager-#{@affiliation.id}-#{@managed_affiliation.id}.sql"
    @file_path = source_dir.join(file_name)
    File.write(@file_path, "#{@sql_log.join("\r\n")}\r\n")
  end
end
