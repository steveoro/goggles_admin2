# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::StandardTimingsImport ('standard_timings.import')
    #
    # Imports the standard timings of a season from the FIN source file under crawler/data/standard_timings/<season>/
    # (discovered as 'import:standard_timings' did, or named by +source+) with Import::StandardTimings. The dry run
    # shows the file used, the sheets, the warnings and the validity errors (any error blocks it before any SQL is
    # built) and the row count.
    #
    # Unlike the other operations its script goes to results.new/<season id>/ (as before) and, once applied locally,
    # starts HELD ('remote_season_missing'): pushing it before the season exists on the remote server fails. The
    # season-start checklist (step 6) releases it after checking the remote season. Confirmation: the checkbox.
    #
    class StandardTimingsImport < Maintenance::Operation
      self.key = 'standard_timings.import'
      self.confirmation = :confirm
      self.outbox_kind = 'standard_timings'
      self.health_group = 'setup'
      self.fixes = [].freeze

      HELD_REASON = 'remote_season_missing'

      param :season_id, :integer, lookup: :season
      param :source, :string

      validates :season_id, presence: true

      attr_reader :importer

      def self.params_from_finding(finding)
        { 'season_id' => finding.season_id || payload_of(finding)['season_id'] }
      end

      def file_base = "#{season_id}-standard_timings"
      def subject = ['season', season_id]
      def label = I18n.t('maintenance.operations.standard_timings_import.label', id: season_id)
      def outbox_folder = season_id.to_s
      def held_reason = HELD_REASON

      # The rake progress lines (one call per event of Import::StandardTimings#call).
      def self.console_lines(event, value)
        case event
        when :source then ["--> Source file: #{value}"]
        when :sheets then ["--> Sheet(s) used: #{Array(value).join(', ')}"]
        when :warning then ["    WARNING: #{value}"]
        when :dupes then ["    (#{value} duplicated rows skipped)"]
        when :read then ["--> Read #{value} rows. Processing...", "\r\n"]
        else []
        end
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity
        season = GogglesDb::Season.find_by(id: season_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: season_id)]) unless season

        console = "--> Season #{season.id}, #{season.header_year}\n"
        @importer = Import::StandardTimings.new(season:, source:).call do |event, value|
          if event == :row
            console << value
          else
            self.class.console_lines(event, value).each { |line| console << line << (line.end_with?("\n") ? '' : "\n") }
          end
        end
        subjects = [{ 'type' => 'season', 'id' => season.id }]
        summary = { 'source' => @importer.filename&.to_s, 'sheets' => @importer.sheets_used, 'rows' => @importer.rows&.size,
                    'inserts' => @importer.inserts_count, 'skipped' => @importer.skipped_count,
                    'existing_standard_timings' => GogglesDb::StandardTiming.where(season_id: season.id).count }.compact
        return blank_plan(subjects:, console:, summary:, warnings: @importer.warnings, errors: @importer.errors) if @importer.errors.any?

        blank_plan(subjects:, console:, summary:, warnings: @importer.warnings + existing_warning(summary), sql_lines: @importer.sql_log)
      end

      private

      def existing_warning(summary)
        count = summary['existing_standard_timings'].to_i
        count.positive? ? [I18n.t('maintenance.operations.standard_timings_import.warnings.existing', count:)] : []
      end
    end
  end
end
