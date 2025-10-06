# frozen_string_literal: true

# Service object to rebuild meeting_session array from an existing meeting
# Extracts complex logic from DataFixController#rescan_phase1_sessions
#
class Phase1SessionRescanner
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

    if @meeting_id.present?
      rebuild_sessions_from_meeting(data)
    else
      clear_sessions(data)
    end

    clear_downstream_data(data)
    save_data(data)
    true
  end

  private

  def rebuild_sessions_from_meeting(data)
    meeting = GogglesDb::Meeting.includes(meeting_sessions: { swimming_pool: :city }).find_by(id: @meeting_id)

    data['meeting_session'] = if meeting
                                meeting.meeting_sessions.order(:session_order).map do |ms|
                                  build_session_hash(ms)
                                end
                              else
                                # Meeting not found, clear sessions
                                []
                              end
  end

  def build_session_hash(meeting_session)
    pool = meeting_session.swimming_pool
    city = pool&.city

    {
      'id' => meeting_session.id,
      'description' => meeting_session.description,
      'session_order' => meeting_session.session_order,
      'scheduled_date' => meeting_session.scheduled_date&.iso8601,
      'day_part_type_id' => meeting_session.day_part_type_id,
      'swimming_pool' => build_pool_hash(pool, city)
    }
  end

  def build_pool_hash(pool, city)
    return {} unless pool

    {
      'id' => pool.id,
      'name' => pool.name,
      'nick_name' => pool.nick_name,
      'address' => pool.address,
      'pool_type_id' => pool.pool_type_id,
      'lanes_number' => pool.lanes_number,
      'maps_uri' => pool.maps_uri,
      'plus_code' => pool.plus_code,
      'latitude' => pool.latitude,
      'longitude' => pool.longitude,
      'city_id' => pool.city_id,
      'city' => build_city_hash(city)
    }
  end

  def build_city_hash(city)
    return {} unless city

    {
      'id' => city.id,
      'name' => city.name,
      'area' => city.area,
      'zip' => city.zip,
      'country' => city.country,
      'country_code' => city.country_code,
      'latitude' => city.latitude,
      'longitude' => city.longitude
    }
  end

  def clear_sessions(data)
    data['meeting_session'] = []
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
