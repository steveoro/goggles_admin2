# frozen_string_literal: true

module Import
  module Committers
    #
    # = Meeting
    #
    # Commits Meeting entities to the production DB, mirroring the behavior
    # previously implemented inside Import::Committers::Main.
    #
    class Meeting
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Commit meeting (returns resulting meeting_id)
      # Returns the committed row ID or raises an error.
      def commit(meeting_hash)
        # Meeting data is currently under the "data" root in phase-1 JSON datafiles:
        meeting_id = meeting_hash['meeting_id'] || meeting_hash['id'] # Support both column names

        # Reuse existing row:
        existing_row = GogglesDb::Meeting.find_by(id: meeting_id) if meeting_id.to_i.positive?
        attributes = normalize_attributes(meeting_hash)

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:meetings_updated] += 1
            logger.log_success(entity_type: 'Meeting', entity_id: meeting_id, action: 'updated',
                               entity_key: existing_row.description)
            Rails.logger.info("[Meeting] Updated ID=#{meeting_id}")
          end
          return meeting_id.to_i
        end

        # Create new row:
        model_row = GogglesDb::Meeting.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "Meeting error (#{model_row.description}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'Meeting',
            entity_key: model_row.description,
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[Meeting] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:meetings_created] += 1
        logger.log_success(entity_type: 'Meeting', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.description)
        Rails.logger.info("[Meeting] Created ID=#{model_row.id}, #{model_row.description}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      # Build normalized attributes matching DB schema
      def normalize_attributes(raw_meeting)
        meeting_hash = raw_meeting.deep_dup

        meeting_hash['description'] = meeting_hash['name']
        meeting_hash['autofilled'] = true if meeting_hash['autofilled'].nil?
        meeting_hash['allows_under25'] = meeting_hash.fetch('allows_under25', true)
        meeting_hash['cancelled'] = meeting_hash.fetch('cancelled', false)
        meeting_hash['confirmed'] = meeting_hash.fetch('confirmed', false)
        meeting_hash['max_individual_events'] ||= GogglesDb::Meeting.columns_hash['max_individual_events'].default
        meeting_hash['max_individual_events_per_session'] ||= GogglesDb::Meeting.columns_hash['max_individual_events_per_session'].default
        meeting_hash['notes'] = build_meeting_notes(meeting_hash)

        sanitize_attributes(meeting_hash, GogglesDb::Meeting)
      end
      # -----------------------------------------------------------------------

      def build_meeting_notes(meeting_hash)
        meeting_url = meeting_hash['meetingURL'] || meeting_hash['meeting_url']
        return meeting_hash['notes'] if meeting_url.blank?

        note_line = "meetingURL: #{meeting_url}"
        existing_notes = meeting_hash['notes']
        return note_line if existing_notes.blank?

        notes = existing_notes.split("\n")
        notes.prepend(note_line) unless notes.include?(note_line)
        notes.join("\n")
      end
      # -----------------------------------------------------------------------

      # These helpers mirror the ones in Main and are scoped here so the
      # behavior remains identical while we incrementally refactor.
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.stringify_keys.slice(*column_names)
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
