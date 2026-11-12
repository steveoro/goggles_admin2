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
      include LegacyPersistence

      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      def prepare_model(meeting_hash, meeting: nil)
        meeting ||= GogglesDb::Meeting.find(meeting_hash['meeting_id']) # Fail fast

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

        # Prefer an existing calendar matched by FIN event ID, then by meeting code/season (or meeting_id)
        existing_row = find_existing_calendar(meeting, fin_event_id_for(meeting_hash))
        attributes = build_calendar_attributes(meeting_hash, meeting, existing: existing_row)

        if existing_row
          changes = changes_for_update(existing_row, protect_existing_values(existing_row, attributes))
          if changes.any?
            existing_row.assign_attributes(changes)
            existing_row.save!
            sql_log << SqlMaker.new(row: existing_row).log_update(changes)
            stats[:calendars_updated] += 1
            logger.log_success(entity_type: 'Calendar', entity_id: existing_row.id, action: 'updated')
            Rails.logger.info("[Calendar] Updated ID=#{existing_row.id}, meeting=#{existing_row.meeting_code}/#{existing_row.meeting_id}")
          end
          return existing_row.id
        end

        model_row = GogglesDb::Calendar.new(attributes.except('id'))

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
      rescue ActiveRecord::RecordNotUnique => e
        # Surface clearer context when hitting DB uniqueness/PK errors
        details = "Calendar insert failed for meeting_id=#{meeting_id}, meeting_code=#{attributes&.dig('meeting_code')}, " \
                  "season_id=#{attributes&.dig('season_id')}: #{e.message}"
        Rails.logger.error("[Calendar] #{details}")
        stats[:errors] << details
        raise
      end
      # -----------------------------------------------------------------------

      private

      # Returns the FIN event ID carried by the results or manifest URL of the meeting hash, or +nil+.
      def fin_event_id_for(meeting_hash)
        FINEventId.parse_any(meeting_hash['meetingURL'], meeting_hash['results_link'],
                             meeting_hash['manifestURL'], meeting_hash['manifest_link'])
      end
      # -----------------------------------------------------------------------

      # Builds the full attribute hash for the calendar row (blank values are compacted away).
      # When +existing+ is not given, it's looked up (FIN event ID first, then code & meeting_id).
      def build_calendar_attributes(meeting_hash, meeting, existing: :lookup)
        fin_event_id = fin_event_id_for(meeting_hash)
        existing = find_existing_calendar(meeting, fin_event_id) if existing == :lookup
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
          'results_code' => fin_event_id,
          'organization_import_text' => meeting_hash['organization'],
          'cancelled' => meeting_hash.key?('cancelled') ? BOOLEAN_TYPE.cast(meeting_hash['cancelled']) : meeting.cancelled,
          'updated_at' => Time.zone.now
        }.compact
      end
      # -----------------------------------------------------------------------

      # Finds the existing calendar row for the meeting, trying in order:
      # 1. same season & same FIN event ID (+results_code+), when the ID is known;
      # 2. same season & same meeting code;
      # 3. same season & same meeting_id.
      def find_existing_calendar(meeting, fin_event_id = nil)
        if fin_event_id.present? && meeting.season_id.present?
          by_fin_id = GogglesDb::Calendar.where(season_id: meeting.season_id, results_code: fin_event_id).first
          return by_fin_id if by_fin_id
        end

        season = meeting.season || GogglesDb::Season.find_by(id: meeting.season_id)
        scopes = if season
                   GogglesDb::Calendar.for_season(season)
                 else
                   GogglesDb::Calendar.where(season_id: meeting.season_id)
                 end
        scopes.for_code(meeting.code).first || scopes.where(meeting_id: meeting.id).first
      end
      # -----------------------------------------------------------------------

      # Drops from the update attributes the values that must not replace the ones already stored:
      # - a FIN +results_link+ is never replaced by a non-FIN URL (e.g. a FICR results page);
      # - a stored +results_code+ (FIN event ID) is never replaced by a different one.
      # (Blank values never overwrite anything, since #changes_for_update skips them.)
      def protect_existing_values(existing_row, attributes)
        protected_keys = []
        protected_keys << 'results_link' if FINEventId.fin_url?(existing_row.results_link) &&
                                            !FINEventId.fin_url?(attributes['results_link'])
        if existing_row.results_code.present? && attributes['results_code'].present? &&
           existing_row.results_code != attributes['results_code']
          Rails.logger.warn("[Calendar] ID=#{existing_row.id}: keeping results_code=#{existing_row.results_code} " \
                            "(incoming FIN event ID #{attributes['results_code']} ignored)")
          protected_keys << 'results_code'
        end
        attributes.except(*protected_keys)
      end
      # -----------------------------------------------------------------------

      def build_meeting_place(meeting_hash)
        [meeting_hash['venue1'], meeting_hash['address1']].compact_blank.join(', ')
      end
      # -----------------------------------------------------------------------
    end
  end
end
