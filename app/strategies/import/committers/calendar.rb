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

      def prepare_model(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        meeting = GogglesDb::Meeting.find_by(id: meeting_id)
        return nil unless meeting

        attributes = build_calendar_attributes(meeting_hash, meeting)
        GogglesDb::Calendar.new(attributes.except('id'))
      end

      # Commit calendar for a given meeting hash (expects meeting_id present).
      # Returns calendar_id or nil.
      def commit(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        meeting = GogglesDb::Meeting.find_by(id: meeting_id)
        return unless meeting

        calendar_attributes = build_calendar_attributes(meeting_hash, meeting)
        calendar_id = calendar_attributes['id']
        model = nil

        begin
          if calendar_id.present?
            existing = GogglesDb::Calendar.find_by(id: calendar_id)
            if existing && attributes_changed?(existing, calendar_attributes)
              existing.update!(calendar_attributes)
              sql_log << SqlMaker.new(row: existing).log_update
              stats[:calendars_updated] += 1
              Rails.logger.info("[Main] Updated Calendar ID=#{existing.id}")
            end
            return existing&.id
          end

          model = prepare_model(meeting_hash)
          model.save!
          sql_log << SqlMaker.new(row: model).log_insert
          stats[:calendars_created] += 1
          Rails.logger.info("[Main] Created Calendar ID=#{model.id}, meeting_id=#{meeting_id}")
          model.id
        rescue ActiveRecord::RecordInvalid => e
          model_row = e.record || model
          error_details = if model_row
                            GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                          else
                            e.message
                          end

          stats[:errors] << "Calendar error: #{error_details}"
          logger.log_validation_error(
            entity_type: 'Calendar',
            entity_key: meeting.code || meeting_hash['meeting_code'],
            entity_id: model_row&.id,
            model_row: model_row,
            error: e
          )
          Rails.logger.error("[Main] ERROR committing calendar: #{error_details}")
          raise
        end
      end

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

      def find_existing_calendar(meeting)
        season = meeting.season || GogglesDb::Season.find_by(id: meeting.season_id)
        scopes = if season
                   GogglesDb::Calendar.for_season(season)
                 else
                   GogglesDb::Calendar.where(season_id: meeting.season_id)
                 end
        scopes.for_code(meeting.code).first || scopes.where(meeting_id: meeting.id).first
      end

      def build_meeting_place(meeting_hash)
        [meeting_hash['venue1'], meeting_hash['address1']].compact_blank.join(', ')
      end

      # These helpers mirror the ones in Main and are scoped here so the
      # behavior remains identical while we incrementally refactor.
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
      end

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
    end
  end
end
