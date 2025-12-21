# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingSession
    #
    # Commits MeetingSession entities to the DB, mirroring the behavior
    # previously implemented inside Import::Committers::Main#commit_meeting_session
    # (minus the nested City/SwimmingPool logic, which is orchestrated by Main).
    #
    class MeetingSession
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Commit a MeetingSession entity.
      # Expects session_hash to already include meeting_id and (optionally) swimming_pool_id.
      # Returns the committed row ID or raises an error.
      def commit(session_hash)
        session_id = session_hash['meeting_session_id'] || session_hash['id']
        meeting_id = session_hash['meeting_id']
        raise StandardError, 'Null meeting_id found in datafile object!' if meeting_id.to_i.zero?

        attributes = normalize_attributes(session_hash)

        # Reuse existing row:
        existing_row = GogglesDb::MeetingSession.find_by(id: session_id) if session_id.to_i.positive?

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:sessions_updated] += 1
            logger.log_success(entity_type: 'MeetingSession', entity_id: session_id, action: 'updated',
                               entity_key: "order #{existing_row.session_order}")
            Rails.logger.info("[MeetingSession] Updated ID=#{session_id}")
          end
          return session_id.to_i
        end

        # Create new row:
        model_row = GogglesDb::MeetingSession.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "MeetingSession error (team_key=#{attributes['team_key']}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'MeetingSession',
            entity_key: attributes['description'],
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[MeetingSession] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:sessions_created] += 1
        logger.log_success(entity_type: 'MeetingSession', entity_id: model_row.id, action: 'created',
                           entity_key: "order #{model_row.session_order}")
        Rails.logger.info("[MeetingSession] Created ID=#{model_row.id}, order=#{model_row.session_order}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      # Build normalized attributes matching DB schema
      def normalize_attributes(raw_session_hash)
        session_hash = raw_session_hash.deep_dup

        session_hash['description'] ||= "Session #{session_hash['session_order']}"
        session_hash['autofilled'] = true if session_hash['autofilled'].nil?

        sanitize_attributes(session_hash, GogglesDb::MeetingSession)
      end
      # -----------------------------------------------------------------------

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
