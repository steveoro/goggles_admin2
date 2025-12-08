# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingEvent
    #
    # Commits MeetingEvent entities to the production DB.
    # MeetingEvents link MeetingSessions to EventTypes.
    #
    class MeetingEvent
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @next_event_order = 1 # Progressive event order counter
      end

      def prepare_model(event_hash)
        attributes = normalize_attributes(event_hash)
        GogglesDb::MeetingEvent.new(attributes)
      end

      # Commit a MeetingEvent entity.
      # Returns the committed row ID or raises an error.
      def commit(event_hash)
        meeting_event_id = event_hash['meeting_event_id']
        meeting_session_id = event_hash['meeting_session_id']
        event_type_id = event_hash['event_type_id']
        model = nil

        # Guard clause: skip if missing required keys
        unless meeting_session_id && event_type_id
          stats[:errors] << "MeetingEvent error: missing required keys (session=#{meeting_session_id}, type=#{event_type_id})"
          return nil
        end

        # If event_id exists and valid, check for updates
        if meeting_event_id.present? && meeting_event_id.to_i.positive?
          existing = GogglesDb::MeetingEvent.find_by(id: meeting_event_id)
          if existing
            attributes = normalize_attributes(event_hash)
            if attributes_changed?(existing, attributes)
              existing.update!(attributes)
              sql_log << SqlMaker.new(row: existing).log_update
              stats[:events_updated] += 1
              logger.log_success(entity_type: 'MeetingEvent', entity_id: existing.id, action: 'updated',
                                 entity_key: existing.event_type&.code)
              Rails.logger.info("[MeetingEvent] Updated ID=#{existing.id}")
            end
            return existing.id
          end
        end

        attributes = normalize_attributes(event_hash)

        # Find existing event by unique key (session + event_type)
        existing = GogglesDb::MeetingEvent.find_by(
          meeting_session_id: meeting_session_id,
          event_type_id: event_type_id
        )

        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            stats[:events_updated] += 1
            logger.log_success(entity_type: 'MeetingEvent', entity_id: existing.id, action: 'updated',
                               entity_key: existing.event_type&.code)
            Rails.logger.info("[MeetingEvent] Updated ID=#{existing.id} (matched by session+type)")
          end
          return existing.id
        end

        # Create new event
        model = prepare_model(event_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:events_created] += 1
        logger.log_success(entity_type: 'MeetingEvent', entity_id: model.id, action: 'created',
                           entity_key: model.event_type&.code)
        Rails.logger.info("[MeetingEvent] Created ID=#{model.id}, session=#{meeting_session_id}, type=#{event_type_id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = "session=#{meeting_session_id},type=#{event_type_id}"
        stats[:errors] << "MeetingEvent error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingEvent',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[MeetingEvent] ERROR: #{error_details}")
        raise
      end

      private

      def normalize_attributes(event_hash)
        normalized = event_hash.deep_dup.with_indifferent_access

        # Progressive event_order: use provided value or assign next in sequence
        if normalized['event_order'].present? && normalized['event_order'].to_i.positive?
          event_order = normalized['event_order'].to_i
          # Update next_event_order to be at least value + 1
          @next_event_order = [event_order + 1, @next_event_order].max
        else
          normalized['event_order'] = @next_event_order
          @next_event_order += 1
        end

        # Default autofilled to true for Phase 4 data (regenerated from source)
        normalized['autofilled'] = true unless normalized.key?('autofilled')

        normalized['heat_type_id'] ||= GogglesDb::HeatType::FINALS_ID
        sanitize_attributes(normalized, GogglesDb::MeetingEvent)
      end

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
