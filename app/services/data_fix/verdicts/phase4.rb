# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Phase4 (events)
    #
    # Blocked: an event type that can't be resolved (as Import::Committers::Main#resolve_event_type_id does); an event
    # whose session order is missing from phase 1 (Main silently skips it); an event whose own session order differs
    # from its parent session (the Phase 5 lookup key would miss it). Review: unmatched events in a meeting that
    # already has events.
    #
    class Phase4 < Base
      PHASE = 4

      protected

      def check # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        sessions = Array(data['sessions'])
        phase1_sessions = Array(pipeline.phase_data(1)['meeting_session'])
        known_orders = phase1_sessions.each_with_index.to_set { |session, index| (session['session_order'] || (index + 1)).to_i }
        events = sessions.flat_map { |session| Array(session['events']).map { |event| [session, event] } }

        unresolved = events.reject { |_session, event| event['event_type_id'].present? || resolvable_event_type?(event) }
        blocked!(:event_type_unresolved, count: unresolved.size, details: unresolved.map { |_session, event| event['key'] })
        if pipeline.phase_exists?(1)
          orphan = sessions.reject { |session| known_orders.include?(session['session_order'].to_i) }
          blocked!(:session_missing, count: orphan.sum { |session| Array(session['events']).size },
                                     details: orphan.pluck('session_order'))
        end
        mismatched = events.select { |session, event| event['session_order'].present? && event['session_order'].to_i != session['session_order'].to_i }
        blocked!(:session_order_mismatch, count: mismatched.size, details: mismatched.map { |_session, event| event['key'] })

        unmatched = events.count { |_session, event| event['id'].blank? && event['meeting_event_id'].blank? }
        review!(:unmatched_events, count: unmatched) if existing_meeting_events?(phase1_sessions)

        counts.merge!('sessions' => sessions.size, 'events' => events.size, 'unmatched' => unmatched)
      end

      private

      def resolvable_event_type?(event)
        key = event['key'].to_s.gsub(/(\d)x(\d)/i, '\1X\2').upcase
        return true if key.present? && event_type_code?(key)

        event['distance'].to_i.positive? && event['stroke'].present? && event_type_code?("#{event['distance']}#{event['stroke']}".upcase)
      end

      def event_type_code?(code)
        (@event_type_codes ||= GogglesDb::EventType.pluck(:code).to_set).include?(code)
      end

      def existing_meeting_events?(phase1_sessions)
        session_ids = phase1_sessions.filter_map { |session| session['id'] }
        pipeline.phase_data(1)['id'].present? && session_ids.any? && GogglesDb::MeetingEvent.exists?(meeting_session_id: session_ids)
      end
    end
  end
end
