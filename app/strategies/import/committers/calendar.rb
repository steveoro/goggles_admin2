# frozen_string_literal: true

module Import
  module Committers
    #
    # = Calendar
    #
    # Commits Calendar entities related to a Meeting, mirroring the behavior
    # previously implemented inside Import::Committers::Main.
    #
    class Calendar
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      def prepare_model(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        meeting = GogglesDb::Meeting.find(meeting_id) # Fail fast

        attributes = build_calendar_attributes(meeting_hash, meeting)
        GogglesDb::Calendar.new(attributes.except('id'))
      end
      # -----------------------------------------------------------------------

      # Commit calendar for a given meeting hash (expects meeting_id present).
      # Returns the committed row ID or raises an error.
      def commit(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        raise StandardError, 'Null meeting_id in datafile object!' if meeting_id.blank?

        meeting = GogglesDb::Meeting.find(meeting_id) # Always fail fast

        attributes = build_calendar_attributes(meeting_hash, meeting)
        calendar_id = attributes['id']
        # Search existing row for a possible update:
        existing_row = GogglesDb::Calendar.find_by(id: calendar_id) if calendar_id.present?

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:calendars_updated] += 1
            logger.log_success(entity_type: 'Calendar', entity_id: existing_row.id, action: 'updated')
            Rails.logger.info("[Calendar] Updated ID=#{existing_row.id}, meeting=#{existing_row.meeting_code}/#{existing_row.meeting_id}")
          end
          return existing_row.id
        end

        # Create new row but do also an additional search by meeting_code and season_id if possible:
        model_row = prepare_model(meeting_hash)
        existing_row = GogglesDb::Calendar.find_by(meeting_code: model_row.meeting_code, season_id: model_row.season_id) if model_row.meeting_code.present? && model_row.season_id.present?

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "Calendar error (#{model_row.meeting_code}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'Calendar',
            entity_key: model_row.meeting_code,
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[Calendar] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:calendars_created] += 1
        logger.log_success(entity_type: 'Calendar', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.meeting_code)
        Rails.logger.info("[Calendar] Created ID=#{model_row.id}, #{model_row.meeting_code}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def build_calendar_attributes(meeting_hash, meeting)
        existing = find_existing_calendar(meeting)
        scheduled_date = meeting.header_date || meeting_hash['scheduled_date']

        {
          'id' => existing&.id,
          'meeting_id' => meeting.id,
          'meeting_code' => meeting.code || meeting_hash['meeting_code'],
          'meeting_name' => meeting.description || meeting_hash['meeting_name'],
          'scheduled_date' => scheduled_date,
          'meeting_place' => build_meeting_place(meeting_hash),
          'season_id' => meeting.season_id || meeting_hash['season_id'],
          'year' => meeting_hash['dateYear1'] || scheduled_date&.year&.to_s,
          'month' => meeting_hash['dateMonth1'] || scheduled_date&.strftime('%m'),
          'results_link' => meeting_hash['meetingURL'] || meeting_hash['results_link'],
          'manifest_link' => meeting_hash['manifestURL'] || meeting_hash['manifest_link'],
          'organization_import_text' => meeting_hash['organization'],
          'cancelled' => meeting_hash.key?('cancelled') ? BOOLEAN_TYPE.cast(meeting_hash['cancelled']) : meeting.cancelled,
          'updated_at' => Time.zone.now
        }.compact
      end
      # -----------------------------------------------------------------------

      def find_existing_calendar(meeting)
        season = meeting.season || GogglesDb::Season.find_by(id: meeting.season_id)
        scopes = if season
                   GogglesDb::Calendar.for_season(season)
                 else
                   GogglesDb::Calendar.where(season_id: meeting.season_id)
                 end
        scopes.for_code(meeting.code).first || scopes.where(meeting_id: meeting.id).first
      end
      # -----------------------------------------------------------------------

      def build_meeting_place(meeting_hash)
        [meeting_hash['venue1'], meeting_hash['address1']].compact_blank.join(', ')
      end
      # -----------------------------------------------------------------------

      # These helpers mirror the ones in Main and are scoped here so the
      # behavior remains identical while we incrementally refactor.
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
      end
      # -----------------------------------------------------------------------

      def attributes_changed?(model, new_attributes)
        new_attributes.except('id', :id).any? do |key, value|
          model_value = begin
            model.send(key.to_sym)
          rescue NoMethodError
            nil
          end
          model_value != value
        end
      end
      # -----------------------------------------------------------------------
    end
  end
end
