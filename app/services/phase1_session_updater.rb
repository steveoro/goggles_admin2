# frozen_string_literal: true

# Service object to update a session in Phase 1 data file
# Extracts complex logic from DataFixController#update_phase1_session
#
class Phase1SessionUpdater
  # @param phase_file_manager [PhaseFileManager] The phase file manager instance
  # @param session_index [Integer] The index of the session to update
  # @param params [ActionController::Parameters] The request parameters
  def initialize(phase_file_manager, session_index, params)
    @pfm = phase_file_manager
    @session_index = session_index
    @params = params
  end

  # Update the session and return success status
  # @return [Boolean] true if update succeeded, false otherwise
  def call
    data = @pfm.data || {}
    sessions = Array(data['meeting_session'])

    return false if @session_index.negative? || @session_index >= sessions.size

    sess = sessions[@session_index]
    update_session_fields(sess)
    update_pool_data(sess)
    update_city_data(sess)
    enrich_city_from_db(sess)

    data['meeting_session'] = sessions
    save_data(data)
    true
  end

  private

  def update_session_fields(sess)
    # Basic session fields
    if @params.key?(:meeting_session_id)
      raw = @params[:meeting_session_id].to_s.strip
      sess_id = raw.present? ? raw.to_i : nil
      sess['id'] = sess_id.to_i.positive? ? sess_id : nil
    end
    sess['description'] = sanitize_str(@params[:description]) if @params[:description].present?
    sess['session_order'] = @params[:session_order].to_i if @params[:session_order].present?
    sess['day_part_type_id'] = @params[:day_part_type_id].to_i if @params[:day_part_type_id].present?

    # Scheduled date with validation
    return if @params[:scheduled_date].blank?

    sd = @params[:scheduled_date].to_s.strip
    if sd.match?(/^\d{4}-\d{2}-\d{2}$/)
      sess['scheduled_date'] = sd
    else
      Rails.logger.warn("Invalid scheduled_date format: #{sd}")
    end
  end

  def update_pool_data(sess)
    allowed_pool_keys = %w[id swimming_pool_id name nick_name address pool_type_id lanes_number maps_uri plus_code latitude longitude city_id]
    pool_data = Phase1NestedParamParser.parse(@params[:pool], allowed_pool_keys, @session_index)

    return unless pool_data.is_a?(Hash)

    sess['swimming_pool'] ||= {}

    # IDs first
    if pool_data.key?('id')
      raw = pool_data['id'].to_s.strip
      pool_id = raw.present? ? raw.to_i : nil
      sess['swimming_pool']['id'] = pool_id.to_i.positive? ? pool_id : nil
    end
    if pool_data.key?('swimming_pool_id')
      raw = pool_data['swimming_pool_id'].to_s.strip
      pool_id = raw.present? ? raw.to_i : sess['swimming_pool']['id']
      sess['swimming_pool']['id'] = pool_id.to_i.positive? ? pool_id : nil
    end
    if pool_data.key?('city_id')
      raw = pool_data['city_id'].to_s.strip
      city_id = raw.present? ? raw.to_i : nil
      sess['swimming_pool']['city_id'] = city_id.to_i.positive? ? city_id : nil
    end

    # String fields
    sess['swimming_pool']['name'] = sanitize_str(pool_data['name']) if pool_data['name'].present?
    sess['swimming_pool']['nick_name'] = sanitize_str(pool_data['nick_name']) if pool_data['nick_name'].present?
    sess['swimming_pool']['address'] = sanitize_str(pool_data['address']) if pool_data['address'].present?

    # Integer fields
    sess['swimming_pool']['pool_type_id'] = pool_data['pool_type_id'].to_i if pool_data['pool_type_id'].present?
    sess['swimming_pool']['lanes_number'] = pool_data['lanes_number'].to_i if pool_data['lanes_number'].present?

    # Optional fields
    sess['swimming_pool']['maps_uri'] = sanitize_str(pool_data['maps_uri']) if pool_data.key?('maps_uri')
    sess['swimming_pool']['plus_code'] = sanitize_str(pool_data['plus_code']) if pool_data.key?('plus_code')
    sess['swimming_pool']['latitude'] = pool_data['latitude'].to_s.strip if pool_data.key?('latitude')
    sess['swimming_pool']['longitude'] = pool_data['longitude'].to_s.strip if pool_data.key?('longitude')
  end

  def update_city_data(sess)
    allowed_city_keys = %w[id city_id name area zip country country_code latitude longitude]
    city_data = Phase1NestedParamParser.parse(@params[:city], allowed_city_keys, @session_index)

    return unless city_data.is_a?(Hash)

    sess['swimming_pool'] ||= {}
    sess['swimming_pool']['city'] ||= {}

    # IDs first (support either id or city_id)
    if city_data.key?('id')
      raw = city_data['id'].to_s.strip
      city_id = raw.present? ? raw.to_i : nil
      sess['swimming_pool']['city']['id'] = city_id.to_i.positive? ? city_id : nil
    end
    if city_data.key?('city_id')
      raw = city_data['city_id'].to_s.strip
      city_id = raw.present? ? raw.to_i : sess['swimming_pool']['city']['id']
      sess['swimming_pool']['city']['id'] = city_id.to_i.positive? ? city_id : nil
    end

    # String fields
    sess['swimming_pool']['city']['name'] = sanitize_str(city_data['name']) if city_data['name'].present?
    sess['swimming_pool']['city']['area'] = sanitize_str(city_data['area']) if city_data['area'].present?
    sess['swimming_pool']['city']['zip'] = sanitize_str(city_data['zip']) if city_data['zip'].present?
    sess['swimming_pool']['city']['country'] = sanitize_str(city_data['country']) if city_data['country'].present?
    sess['swimming_pool']['city']['country_code'] = sanitize_str(city_data['country_code']) if city_data['country_code'].present?

    # Coordinates
    sess['swimming_pool']['city']['latitude'] = city_data['latitude'].to_s.strip if city_data.key?('latitude')
    sess['swimming_pool']['city']['longitude'] = city_data['longitude'].to_s.strip if city_data.key?('longitude')
  end

  def enrich_city_from_db(sess)
    city = sess.dig('swimming_pool', 'city')
    return unless city.is_a?(Hash)

    city_id = city['id'] || city['city_id']
    return unless city_id.to_i.positive?

    needed_fields = %w[name country area zip country_code latitude longitude]
    missing = needed_fields.any? { |k| city[k].to_s.strip.empty? }
    return unless missing

    db_city = GogglesDb::City.find_by(id: city_id)
    return unless db_city

    city['id'] = db_city.id
    city['city_id'] ||= db_city.id
    city['name'] ||= db_city.name
    city['area'] ||= db_city.area
    city['zip'] ||= db_city.zip
    city['country'] ||= db_city.country
    city['country_code'] ||= db_city.country_code
    city['latitude'] ||= db_city.latitude&.to_s
    city['longitude'] ||= db_city.longitude&.to_s
  end

  def save_data(data)
    meta = @pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    @pfm.write!(data: data, meta: meta)
  end

  def sanitize_str(value)
    return nil if value.blank?

    value.to_s.strip.presence
  end
end
