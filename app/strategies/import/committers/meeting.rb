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

      # Build normalized meeting attributes matching DB schema
      # NOTE: This is a direct extraction of Main#normalize_meeting_attributes
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

        meeting_hash
      end

      def prepare_model(meeting_hash)
        attributes = sanitize_attributes(meeting_hash, GogglesDb::Meeting)
        GogglesDb::Meeting.new(attributes)
      end

      # Commit meeting (returns resulting meeting_id)
      # NOTE: This is a direct extraction of Main#commit_meeting
      def commit(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        model = nil

        # If meeting already has a DB ID, it's matched - update if needed
        if meeting_id.present? && meeting_id.positive?
          meeting = GogglesDb::Meeting.find_by(id: meeting_id)
          if meeting && attributes_changed?(meeting, meeting_hash)
            attributes_for_logging = sanitize_attributes(meeting_hash, GogglesDb::Meeting)
            meeting.update!(attributes_for_logging)
            sql_log << SqlMaker.new(row: meeting).log_update
            stats[:meetings_updated] += 1
            Rails.logger.info("[Main] Updated Meeting ID=#{meeting_id}")
          end
          return meeting_id
        end

        model = prepare_model(meeting_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:meetings_created] += 1
        logger.log_success(entity_type: 'Meeting', entity_id: model.id, action: 'created')
        Rails.logger.info("[Main] Created Meeting ID=#{model.id}, #{model.description}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "Meeting error: #{error_details}"
        logger.log_validation_error(
          entity_type: 'Meeting',
          entity_key: meeting_hash['name'] || meeting_hash['code'],
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing meeting: #{error_details}")
        raise
      end

      private

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
