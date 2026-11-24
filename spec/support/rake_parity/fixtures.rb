# frozen_string_literal: true

require 'fileutils'

#
# = RakeParity::Fixtures (phase 13)
#
# Deterministic case data for the rake parity baselines, built inside the spec transaction from existing goggles_test
# rows (fixed ids; the ids of the rows created here vary per run and become tokens, see RakeParity.normalize).
#
module RakeParity
  module Fixtures
    # Seasons, meetings, teams and badges of goggles_test used by the cases (season 182 holds real-like results).
    SEASON = 182
    BADGE_A = 115_299 # swimmer 38933, team 1292
    BADGE_B = 115_303 # swimmer 15698, team 1292
    TEAM_A = 1292
    RELAY_CATEGORY = 1264 # '000-999' (season 182)

    # Seasons above this id are factory leftovers committed by other suites on the shared goggles_test DB.
    LEFTOVER_SEASON_ID = 10_000

    module_function

    # Hides (inside the spec transaction only) the factory seasons left on the shared goggles_test DB: strategies
    # reading "the latest seasons of a type" (Merge::BadgeChecker.map_categories_x_seasons) would otherwise depend on
    # them. The rows come back with the rollback.
    def hide_leftover_seasons!
      connection = ActiveRecord::Base.connection
      connection.execute('SET FOREIGN_KEY_CHECKS = 0')
      connection.execute("DELETE FROM seasons WHERE id > #{LEFTOVER_SEASON_ID}")
    ensure
      connection&.execute('SET FOREIGN_KEY_CHECKS = 1')
    end

    # A copy of an existing badge (same swimmer, team, season, category): a sure duplicate for BadgeSeasonChecker.
    def duplicate_badge(badge_id, number: 'PARITY')
      source = GogglesDb::Badge.find(badge_id)
      attributes = source.attributes.except('id', 'lock_version', 'created_at', 'updated_at').merge('number' => number)
      GogglesDb::Badge.create!(attributes)
    end

    # Moves the first +count+ MIRs (by id) of +from_badge_id+ to +to_badge+.
    def move_mirs(from_badge_id, to_badge, count:)
      ids = GogglesDb::MeetingIndividualResult.where(badge_id: from_badge_id).order(:id).limit(count).pluck(:id)
      GogglesDb::MeetingIndividualResult.where(id: ids).update_all(badge_id: to_badge.id) # rubocop:disable Rails/SkipsModelValidations
      ids
    end

    # Puts the badge on a relay-only category (a 'relay_badges' candidate).
    def relay_category!(badge_id, category_type_id = RELAY_CATEGORY)
      GogglesDb::Badge.where(id: badge_id).update_all(category_type_id:) # rubocop:disable Rails/SkipsModelValidations
    end

    # Clears the swimmer of the first +count+ MIRs (by id) of a meeting (their badge still has the swimmer).
    def null_swimmers!(meeting_id, count:)
      ids = GogglesDb::MeetingIndividualResult.joins(meeting_program: { meeting_event: :meeting_session })
                                              .where(meeting_sessions: { meeting_id: }).order(:id).limit(count).pluck(:id)
      GogglesDb::MeetingIndividualResult.where(id: ids).update_all(swimmer_id: nil) # rubocop:disable Rails/SkipsModelValidations
      ids
    end

    # A copy of the first MIR (by id) of a meeting: same program, swimmer, badge and timing (a duplicate result).
    def duplicate_mir(meeting_id)
      source = GogglesDb::MeetingIndividualResult.joins(meeting_program: { meeting_event: :meeting_session })
                                                 .where(meeting_sessions: { meeting_id: }).order(:id).first
      GogglesDb::MeetingIndividualResult.create!(source.attributes.except('id', 'lock_version', 'created_at', 'updated_at'))
    end

    # Header and rows of a small standard-timings XLSX (format 1, sheet 'VERIFICA').
    XLSX_HEADER = ['CATEG', 'COD GARA', 'GARA', 'SESSO', 'VASCA', 'CENTESIMI', 'TEMPO (mmsscc)', 'TEMPO PRINT'].freeze
    XLSX_ROWS = [
      ['M25', 'A1', '50 STILE LIBERO', 'M', '25', 2850, '002850', "0'28\"50"],
      ['M25', 'A1', '50 STILE LIBERO', 'F', '25', 3210, '003210', "0'32\"10"],
      ['M30', 'B2', '100 STILE LIBERO', 'M', '50', 6420, '010420', "1'04\"20"],
      ['M35', 'C3', '50 DORSO', 'F', '50', 3890, '003890', "0'38\"90"]
    ].freeze

    # Writes the XLSX into +dir+ ('<prefix>.xlsx'); returns the path without the extension (the 'source' option).
    def standard_timings_xlsx(dir, prefix: 'mst_tb_ind_parity')
      require 'caxlsx'
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{prefix}.xlsx")
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: 'VERIFICA') do |sheet|
        sheet.add_row(XLSX_HEADER)
        XLSX_ROWS.each { |row| sheet.add_row(row, types: %i[string string string string string integer string string]) }
      end
      package.serialize(path)
      path.delete_suffix('.xlsx')
    end
  end
end
