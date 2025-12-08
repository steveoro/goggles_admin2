# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingProgram
    #
    # Commits MeetingProgram entities to the production DB.
    # MeetingPrograms link MeetingEvents to specific category+gender combinations.
    #
    class MeetingProgram
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @next_event_order = 1 # Progressive event order counter across all programs
      end

      def prepare_model(program_hash)
        attributes = normalize_attributes(program_hash)
        GogglesDb::MeetingProgram.new(attributes)
      end

      # Commit a MeetingProgram entity.
      # Returns the committed row ID or raises an error.
      def commit(program_hash)
        meeting_program_id = program_hash['meeting_program_id']
        meeting_event_id = program_hash['meeting_event_id']
        category_type_id = program_hash['category_type_id']
        gender_type_id = program_hash['gender_type_id']
        model = nil

        # Guard clause: skip if missing required keys
        unless meeting_event_id && category_type_id && gender_type_id
          stats[:errors] << "MeetingProgram error: missing required keys (event=#{meeting_event_id}, cat=#{category_type_id}, gender=#{gender_type_id})"
          return nil
        end

        # If program_id exists, it's already in DB - just return it
        if meeting_program_id.present? && meeting_program_id.to_i.positive?
          Rails.logger.debug { "[MeetingProgram] ID=#{meeting_program_id} already exists, skipping" }
          return meeting_program_id
        end

        attributes = normalize_attributes(program_hash)

        # Find existing program by unique key (event + category + gender)
        existing = GogglesDb::MeetingProgram.find_by(
          meeting_event_id: meeting_event_id,
          category_type_id: category_type_id,
          gender_type_id: gender_type_id
        )

        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            stats[:programs_updated] += 1
            logger.log_success(entity_type: 'MeetingProgram', entity_id: existing.id, action: 'updated')
            Rails.logger.info("[MeetingProgram] Updated ID=#{existing.id}")
          end
          return existing.id
        end

        # Create new program
        model = prepare_model(program_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:programs_created] += 1
        logger.log_success(entity_type: 'MeetingProgram', entity_id: model.id, action: 'created')
        Rails.logger.info("[MeetingProgram] Created ID=#{model.id}, event=#{meeting_event_id}, cat=#{category_type_id}, gender=#{gender_type_id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = "event=#{meeting_event_id},cat=#{category_type_id},gender=#{gender_type_id}"
        stats[:errors] << "MeetingProgram error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingProgram',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[MeetingProgram] ERROR: #{error_details}")
        raise
      end

      private

      def normalize_attributes(program_hash)
        normalized = program_hash.deep_dup.with_indifferent_access

        # Progressive event_order: use provided value or assign next in sequence
        if normalized['event_order'].present? && normalized['event_order'].to_i.positive?
          event_order = normalized['event_order'].to_i
          # Update next_event_order to be at least value + 1
          @next_event_order = [event_order + 1, @next_event_order].max
        else
          normalized['event_order'] = @next_event_order
          @next_event_order += 1
        end

        # Resolve pool_type_id from MeetingEvent → MeetingSession → SwimmingPool
        if normalized['pool_type_id'].blank?
          meeting_event_id = normalized['meeting_event_id']
          if meeting_event_id
            meeting_event = GogglesDb::MeetingEvent.find_by(id: meeting_event_id)
            normalized['pool_type_id'] = meeting_event.meeting_session.swimming_pool.pool_type_id if meeting_event&.meeting_session&.swimming_pool
          end
        end

        sanitize_attributes(normalized, GogglesDb::MeetingProgram)
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
