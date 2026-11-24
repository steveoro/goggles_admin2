# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::CodedNamesNormalize ('coded_names.normalize')
    #
    # Normalizes every coded name (Meeting#code, edition and edition type; SwimmingPool#nick_name) with the shared
    # goggles_db normalizers and the exact calls of 'normalize:coded_names':
    #   Normalize::CodedNames.new(limit:)#call, #change_log, #duplicate_pool_ids, #stats, #single_transaction_sql_log
    # Pools whose new nick name already exists are skipped (warnings). Cross-season (no health re-run). Typed
    # confirmation ("NORMALIZE").
    #
    class CodedNamesNormalize < Maintenance::Operation
      self.key = 'coded_names.normalize'
      self.confirmation = :typed
      self.outbox_kind = 'normalize'
      self.health_group = nil
      self.fixes = [].freeze

      MAX_CHANGES_LISTED = 500

      param :limit

      validates :limit, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

      attr_reader :normalizer

      def self.params_from_finding(_finding) = {}

      def file_base = 'normalize_coded_names'
      def label = I18n.t('maintenance.operations.coded_names_normalize.label', limit: limit.to_i.positive? ? limit : '-')
      def typed_token = 'NORMALIZE'

      protected

      def build_plan
        @normalizer = Normalize::CodedNames.new(limit: limit.to_i)
        @normalizer.call
        duplicates = @normalizer.duplicate_pool_ids
        blank_plan(summary: { 'stats' => @normalizer.stats.transform_keys(&:to_s), 'duplicate_pool_ids' => duplicates,
                              'changes' => @normalizer.change_log.first(MAX_CHANGES_LISTED) },
                   warnings: duplicates.present? ? [I18n.t('maintenance.operations.coded_names_normalize.warnings.duplicates', ids: duplicates.join(', '))] : [],
                   sql_lines: @normalizer.single_transaction_sql_log)
      end
    end
  end
end
