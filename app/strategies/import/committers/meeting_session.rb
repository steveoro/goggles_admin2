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

      def prepare_model(session_hash)
        normalized_session = sanitize_attributes(session_hash, GogglesDb::MeetingSession)
        GogglesDb::MeetingSession.new(normalized_session)
      end

      # Commit a MeetingSession entity.
      # Expects session_hash to already include meeting_id and (optionally)
      # swimming_pool_id.
      # Returns session_id or nil.
      def commit(session_hash)
        session_id = session_hash['meeting_session_id'] || session_hash['id']
        meeting_id = session_hash['meeting_id']

        return unless meeting_id

        normalized_session = sanitize_attributes(session_hash, GogglesDb::MeetingSession)
        model = nil

        # If session already has a DB ID, update if needed
        if session_id.present? && session_id.positive?
          session = GogglesDb::MeetingSession.find_by(id: session_id)
          if session && attributes_changed?(session, normalized_session)
            session.update!(normalized_session)
            sql_log << SqlMaker.new(row: session).log_update
            stats[:sessions_updated] += 1
            logger.log_success(entity_type: 'MeetingSession', entity_id: session_id, action: 'updated',
                               entity_key: "order #{session.session_order}")
            Rails.logger.info("[Main] Updated MeetingSession ID=#{session_id}")
          end
          return session_id
        end

        model = prepare_model(session_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:sessions_created] += 1
        logger.log_success(entity_type: 'MeetingSession', entity_id: model.id, action: 'created',
                           entity_key: "order #{model.session_order}")
        Rails.logger.info("[Main] Created MeetingSession ID=#{model.id}, order=#{model.session_order}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "MeetingSession error: #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingSession',
          entity_key: session_hash['description'],
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing session: #{error_details}")
        raise
      end

      private

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
