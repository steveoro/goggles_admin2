# frozen_string_literal: true

# Service object to rebuild meeting_session array from an existing meeting
# Extracts complex logic from DataFixController#rescan_phase1_sessions
#
class Phase1SessionRescanner
  include Import::Solvers::SessionHashBuilder

  # @param phase_file_manager [PhaseFileManager] The phase file manager instance
  # @param meeting_id [String, Integer, nil] The meeting ID to rescan from
  def initialize(phase_file_manager, meeting_id)
    @pfm = phase_file_manager
    @meeting_id = meeting_id&.to_s&.strip
  end

  # Rebuild sessions array and return success status
  # @return [Boolean] true if rescan succeeded, false otherwise
  def call
    data = @pfm.data || {}

    data['meeting_session'] = []
    rebuild_sessions_from_meeting(data) if @meeting_id.present?
    rebuild_sessions_from_fields(data) if data['meeting_session'].blank?

    clear_downstream_data(data)
    save_data(data)
    true
  end

  private

  def rebuild_sessions_from_meeting(data)
    meeting = GogglesDb::Meeting.includes(meeting_sessions: { swimming_pool: :city }).find_by(id: @meeting_id)

    return unless meeting&.meeting_sessions&.any?

    data['meeting_session'] = meeting.meeting_sessions.order(:session_order).map do |ms|
      build_session_hash(ms)
    end
  end

  def rebuild_sessions_from_fields(data)
    sessions = []
    iso_date1 = parse_iso_date(data['dateDay1'], data['dateMonth1'], data['dateYear1'])
    if iso_date1
      sessions << build_session_hash_from_fields(
        session_order: 1,
        scheduled_date: iso_date1,
        pool_name: data['venue1'],
        address: data['address1'],
        pool_length: data['poolLength']
      )
    end

    iso_date2 = parse_iso_date(data['dateDay2'], data['dateMonth2'], data['dateYear2'])
    if iso_date2
      sessions << build_session_hash_from_fields(
        session_order: 2,
        scheduled_date: iso_date2,
        pool_name: data['venue1'],
        address: data['address1'],
        pool_length: data['poolLength']
      )
    end

    data['meeting_session'] = sessions
  end

  def parse_iso_date(date_day, date_month, date_year)
    return if date_day.blank? || date_month.blank? || date_year.blank?

    Parser::SessionDate.from_l2_result(date_day, date_month, date_year)
  rescue StandardError
    nil
  end

  def clear_downstream_data(data)
    # Clear all downstream phase data when sessions are rebuilt
    data['meeting_event'] = []
    data['meeting_program'] = []
    data['meeting_individual_result'] = []
    data['meeting_relay_result'] = []
    data['lap'] = []
    data['relay_lap'] = []
    data['meeting_relay_swimmer'] = []
  end

  def save_data(data)
    meta = @pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    @pfm.write!(data: data, meta: meta)
  end
end
