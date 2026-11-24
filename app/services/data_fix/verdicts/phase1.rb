# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Phase1 (meeting + sessions)
    #
    # Blocked: Import::StructureValidator invalid; the source asks for a crawl retry; the FIN event id already linked
    # to a calendar of ANOTHER meeting (read-only copy of Import::Committers::Calendar#check_fin_event_link!).
    # Review (until the operator saves Step 1): meeting not matched by FIN event id; extraction warnings in the
    # source '_meta'; a session without id in an existing meeting.
    #
    class Phase1 < Base
      PHASE = 1

      protected

      def check # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        validator = Import::StructureValidator.new(phase1_data: data)
        unless validator.valid?
          messages = validator.error_messages
          blocked!(:structure_invalid, message: messages.first(3).join(' • '), count: [messages.size, 1].max)
        end
        blocked!(:retry_needed) if pipeline.retry_needed?
        check_fin_link!

        unless operator_saved?
          review!(:meeting_not_fin_matched) unless DataFix::ReviewRules.meeting_matched_by_fin?(data)
          warnings = Array(pipeline.source_json.dig('_meta', 'warnings'))
          review!(:source_warnings, count: warnings.size, details: warnings.map(&:to_s))
          review!(:new_session_in_existing_meeting, count: Array(data['meeting_session']).count { |session| session['id'].blank? }) if data['id'].present?
        end

        counts.merge!('sessions' => Array(data['meeting_session']).size, 'meeting_id' => data['id'],
                      'matched_by' => data.dig('meeting_match', 'source'), 'saved' => meta['operator_edit'].present?)
        new_entities['meeting'] = { 'name' => data['name'], 'code' => data['code'] } if data['id'].blank?
      end

      private

      def check_fin_link! # rubocop:disable Metrics/AbcSize
        fin_event_id = FINEventId.parse_any(data['meetingURL'], data['results_link'], data['manifestURL'], data['manifest_link'])
        return if fin_event_id.blank? || data['season_id'].blank?

        row = GogglesDb::Calendar.where(season_id: data['season_id'], results_code: fin_event_id).first
        return if row.nil? || row.meeting_id.nil? || row.meeting_id == data['id'].to_i

        blocked!(:fin_link_conflict, message: "FIN #{fin_event_id} → meeting #{row.meeting_id} (calendar #{row.id})")
      end
    end
  end
end
