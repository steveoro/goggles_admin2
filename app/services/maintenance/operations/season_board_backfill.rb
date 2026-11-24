# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::SeasonBoardBackfill ('season_board.backfill')
    #
    # Links the calendars of a season to their FIN events (calendars.results_code / links) and sets
    # meetings.results_acquired for the meetings with results, from the archived files:
    #   SeasonBoard::Backfill.new(season:, simulate: true).call   (sql_lines = #sql_log, console = #report)
    # The apply goes through the generic Executor path (SQL run locally, then the Outbox), never Backfill#apply!
    # (which writes its own file). A season that is not the Season board season gets an empty watcher snapshot
    # (+snapshot_rows: []+: the current snapshot lists only the board season's FIN rows).
    # One click. Fixes: meetings.results_flag.
    #
    class SeasonBoardBackfill < Maintenance::Operation
      self.key = 'season_board.backfill'
      self.confirmation = :one_click
      self.outbox_kind = 'backfill'
      self.health_group = 'meetings'
      self.fixes = %w[meetings.results_flag].freeze

      param :season_id

      validates :season_id, presence: true

      # Crawler data root read by the backfill (specs: a temporary folder).
      class_attribute :data_root, default: nil

      # The SeasonBoard::Backfill of the last plan (read by the rake caller, phase 13).
      attr_reader :backfill

      def self.params_from_finding(finding)
        { 'season_id' => finding.season_id }
      end

      def file_base = "season_board_backfill-#{season_id}"
      def subject = ['season', season_id]
      def label = I18n.t('maintenance.operations.season_board_backfill.label', id: season_id)

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: season_id)]) unless season

        @backfill = backfill = SeasonBoard::Backfill.new(season:, simulate: true, data_root: data_root || SeasonBoard::Backfill::DEFAULT_DATA_ROOT,
                                                         snapshot_rows: board_season? ? nil : []).call
        blank_plan(subjects: [{ 'type' => 'season', 'id' => season.id }], console: backfill.report.join("\n"),
                   summary: { 'season_id' => season.id, 'board_season' => board_season?, 'resolved' => backfill.resolved.size,
                              'unresolved' => backfill.unresolved.size, 'statements' => backfill.statements.size,
                              'calendars_to_update' => backfill.resolved.count { |row| row[:changes].present? } },
                   warnings: board_season? ? [] : [I18n.t('maintenance.operations.season_board_backfill.warnings.no_snapshot')],
                   sql_lines: backfill.sql_log)
      end

      private

      def season
        return @season if defined?(@season)

        @season = season_id && GogglesDb::Season.find_by(id: season_id)
      end

      def board_season?
        return @board_season if defined?(@board_season)

        @board_season = SeasonBoard::Builder.latest_season&.id == season&.id
      end
    end
  end
end
