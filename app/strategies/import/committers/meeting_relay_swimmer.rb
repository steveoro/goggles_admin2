# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingRelaySwimmer
    #
    # Commits MeetingRelaySwimmer entities to the production DB.
    # Converts from DataImportMeetingRelaySwimmer temporary records.
    #
    class MeetingRelaySwimmer
      attr_reader :stats, :logger, :sql_log

      # Stroke type order for medley relays (MI):
      # 1st = Backstroke, 2nd = Breaststroke, 3rd = Butterfly, 4th = Freestyle
      MEDLEY_STROKE_ORDER = {
        1 => GogglesDb::StrokeType::BACKSTROKE_ID,
        2 => GogglesDb::StrokeType::BREASTSTROKE_ID,
        3 => GogglesDb::StrokeType::BUTTERFLY_ID,
        4 => GogglesDb::StrokeType::FREESTYLE_ID
      }.freeze

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Commit a MeetingRelaySwimmer from a data_import record.
      # @param data_import_mrs [GogglesDb::DataImportMeetingRelaySwimmer] the temp record
      # @param mrr_id [Integer] the resolved meeting_relay_result_id
      # @param swimmer_id [Integer] the resolved swimmer_id (passed explicitly)
      # @param badge_id [Integer] the resolved badge_id (passed explicitly)
      # Returns the committed row ID or raises an error.
      def commit(data_import_mrs)
        mrs_id = data_import_mrs.meeting_relay_swimmer_id
        mrr_id = data_import_mrs.meeting_relay_result_id
        relay_order = data_import_mrs.relay_order.to_i
        attributes = normalize_attributes(data_import_mrs)

        # Compute missing timing (delta or absolute) from previous swimmer if available
        previous_swimmer = find_previous_relay_swimmer(mrr_id, relay_order)
        attributes = compute_missing_timing(attributes, previous_swimmer)

        # If MRS already has a DB ID (matched), update if needed
        if mrs_id.present? && mrs_id.to_i.positive?
          existing = GogglesDb::MeetingRelaySwimmer.find_by(id: mrs_id)
          if existing
            if attributes_changed?(existing, attributes)
              existing.update!(attributes)
              sql_log << SqlMaker.new(row: existing).log_update
              stats[:mrss_updated] += 1
              logger.log_success(entity_type: 'MRS', entity_id: mrs_id, action: 'updated')
              Rails.logger.info("[MRS] Updated ID=#{mrs_id}")
            end
            return mrs_id
          end
        end

        # Create new MRS
        model = GogglesDb::MeetingRelaySwimmer.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:mrss_created] += 1
        logger.log_success(entity_type: 'MRS', entity_id: model.id, action: 'created')
        Rails.logger.info("[MRS] Created ID=#{model.id}, swimmer=#{data_import_mrs.swimmer_id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = data_import_mrs.import_key
        stats[:errors] << "MRS error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingRelaySwimmer',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[MRS] ERROR: #{error_details}")
        raise
      end
      # -----------------------------------------------------------------------

      private

      # Resolve stroke_type_id based on relay type and swimmer order
      # @param import_key [String] e.g., "5-M4X50MI-M80-X/team-timing-swimmer1"
      # @param relay_order [Integer] swimmer's order in the relay (1-4)
      # @return [Integer] stroke_type_id
      def resolve_stroke_type_id(import_key, relay_order)
        # Extract event code from import_key (format: "session-EVENT_CODE-category-gender/...")
        # e.g., "5-M4X50MI-M80-X/..." -> "M4X50MI"
        event_code = import_key.split('-')[1] || ''

        # Check if it's a medley relay (ends with "MI")
        if event_code.end_with?('MI')
          # Medley: stroke depends on swimmer order
          MEDLEY_STROKE_ORDER[relay_order] || GogglesDb::StrokeType::FREESTYLE_ID
        else
          # Other relays (SL, etc.): all swimmers use freestyle
          GogglesDb::StrokeType::FREESTYLE_ID
        end
      end
      # -----------------------------------------------------------------------

      # Find the previous relay swimmer for timing computation
      # @param mrr_id [Integer] meeting_relay_result_id
      # @param current_order [Integer] current swimmer's relay_order
      # @return [GogglesDb::MeetingRelaySwimmer, nil] previous swimmer or nil if not found
      def find_previous_relay_swimmer(mrr_id, current_order)
        return nil unless mrr_id && current_order.to_i > 1

        GogglesDb::MeetingRelaySwimmer
          .where(meeting_relay_result_id: mrr_id)
          .where(relay_order: ...current_order.to_i)
          .order(relay_order: :desc)
          .first
      end

      # Check if timing components are present in attributes
      # @param attrs [Hash] the attributes hash
      # @param type [Symbol] :delta or :absolute
      # @return [Boolean] true if any timing component is present and non-zero
      def timing_present?(attrs, type)
        case type
        when :delta
          attrs['minutes'].to_i.positive? || attrs['seconds'].to_i.positive? || attrs['hundredths'].to_i.positive?
        when :absolute
          attrs['minutes_from_start'].to_i.positive? || attrs['seconds_from_start'].to_i.positive? || attrs['hundredths_from_start'].to_i.positive?
        else
          false
        end
      end

      # Compute missing timing (delta or absolute) from previous swimmer
      # @param attributes [Hash] current swimmer attributes
      # @param previous_swimmer [GogglesDb::MeetingRelaySwimmer, nil] previous swimmer record
      # @return [Hash] updated attributes with computed timing
      def compute_missing_timing(attributes, previous_swimmer)
        delta_present = timing_present?(attributes, :delta)
        absolute_present = timing_present?(attributes, :absolute)

        # Both present or neither present: nothing to compute
        return attributes if delta_present == absolute_present

        if delta_present && !absolute_present
          # Compute absolute = previous_absolute + delta
          delta = Timing.new(
            minutes: attributes['minutes'].to_i,
            seconds: attributes['seconds'].to_i,
            hundredths: attributes['hundredths'].to_i
          )

          if previous_swimmer
            prev_absolute = Timing.new(
              minutes: previous_swimmer.minutes_from_start.to_i,
              seconds: previous_swimmer.seconds_from_start.to_i,
              hundredths: previous_swimmer.hundredths_from_start.to_i
            )
            new_absolute = prev_absolute + delta
          else
            # First swimmer: absolute = delta
            new_absolute = delta
          end

          attributes['minutes_from_start'] = new_absolute.minutes
          attributes['seconds_from_start'] = new_absolute.seconds
          attributes['hundredths_from_start'] = new_absolute.hundredths
          Rails.logger.debug { "[MRS] Computed absolute timing: #{new_absolute}" }

        elsif absolute_present && !delta_present
          # Compute delta = absolute - previous_absolute
          curr_absolute = Timing.new(
            minutes: attributes['minutes_from_start'].to_i,
            seconds: attributes['seconds_from_start'].to_i,
            hundredths: attributes['hundredths_from_start'].to_i
          )

          if previous_swimmer
            prev_absolute = Timing.new(
              minutes: previous_swimmer.minutes_from_start.to_i,
              seconds: previous_swimmer.seconds_from_start.to_i,
              hundredths: previous_swimmer.hundredths_from_start.to_i
            )
            new_delta = curr_absolute - prev_absolute
          else
            # First swimmer: delta = absolute
            new_delta = curr_absolute
          end

          attributes['minutes'] = new_delta.minutes
          attributes['seconds'] = new_delta.seconds
          attributes['hundredths'] = new_delta.hundredths
          Rails.logger.debug { "[MRS] Computed delta timing: #{new_delta}" }
        end

        attributes
      end
      # -----------------------------------------------------------------------

      def normalize_attributes(data_import_mrs)
        relay_order = integer_or_nil(data_import_mrs.relay_order)
        stroke_type_id = resolve_stroke_type_id(data_import_mrs.import_key, relay_order)

        {
          'meeting_relay_result_id' => data_import_mrs.meeting_relay_result_id,
          'swimmer_id' => data_import_mrs.swimmer_id,
          'badge_id' => data_import_mrs.badge_id,
          'stroke_type_id' => stroke_type_id,
          'relay_order' => relay_order,
          'minutes' => integer_or_nil(data_import_mrs.minutes),
          'seconds' => integer_or_nil(data_import_mrs.seconds),
          'hundredths' => integer_or_nil(data_import_mrs.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_mrs.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_mrs.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_mrs.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_mrs.reaction_time),
          'length_in_meters' => integer_or_nil(data_import_mrs.length_in_meters)
        }.compact
      end
      # -----------------------------------------------------------------------

      def integer_or_nil(value)
        return nil if value.blank?

        value.to_i
      end

      def decimal_or_nil(value)
        return nil if value.blank?

        value.to_d
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
