# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::CategoriesClone ('categories.clone')
    #
    # Clones the CategoryType rows missing in a destination season from a source season (optionally deleting some
    # destination codes first) with the exact calls of 'import:categories':
    #   Import::CategoryCloner.new(src_season:, dest_season:, remove_codes:)#prepare, #errors, #log, #sql_log
    # A repair tool of the season-start checklist only: the goggles_db data migration that creates a season inserts its
    # categories on deploy, so a clone pushed from admin2 could collide with it. Its form is opened from the checklist
    # (step 2, when the local season has no CategoryType and the remote season exists), not from the operations list.
    # Confirmation: the checkbox; typed ("CLONE <src> INTO <dest>") when codes are removed.
    #
    class CategoriesClone < Maintenance::Operation
      self.key = 'categories.clone'
      self.confirmation = :confirm
      self.outbox_kind = 'categories'
      self.health_group = 'setup'
      self.fixes = [].freeze

      param :src_season_id, :integer, lookup: :season
      param :dest_season_id, :integer, lookup: :season
      param :remove_codes, :string

      validates :src_season_id, :dest_season_id, presence: true

      attr_reader :cloner

      def self.params_from_finding(_finding) = {}

      # Opened from the season-start checklist only (no form link on /operations).
      def self.checklist_only? = true

      def remove_code_list = remove_codes.to_s.split(',').map(&:strip).compact_blank

      def file_base = "import_categories-#{src_season_id}-#{dest_season_id}"
      def season_id = attributes['dest_season_id']
      def subject = ['season', dest_season_id]
      def label = I18n.t('maintenance.operations.categories_clone.label', source: src_season_id, dest: dest_season_id)
      def typed_token = remove_code_list.any? ? "CLONE #{src_season_id} INTO #{dest_season_id}" : nil
      def confirmation_for(_plan) = remove_code_list.any? ? :typed : :confirm

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        src_season = GogglesDb::Season.find_by(id: src_season_id)
        dest_season = GogglesDb::Season.find_by(id: dest_season_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: src_season_id)]) unless src_season
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: dest_season_id)]) unless dest_season

        @cloner = Import::CategoryCloner.new(src_season:, dest_season:, remove_codes: remove_code_list)
        @cloner.prepare
        subjects = [{ 'type' => 'season', 'id' => src_season.id }, { 'type' => 'season', 'id' => dest_season.id }]
        return blank_plan(subjects:, console: @cloner.log.join("\r\n"), errors: @cloner.errors.map(&:to_s)) if @cloner.errors.present?

        blank_plan(subjects:, console: @cloner.log.join("\r\n"),
                   summary: { 'src_season' => src_season.header_year, 'dest_season' => dest_season.header_year,
                              'dest_categories' => GogglesDb::CategoryType.where(season_id: dest_season.id).count,
                              'remove_codes' => remove_code_list },
                   sql_lines: @cloner.sql_log)
      end
    end
  end
end
