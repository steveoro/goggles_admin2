# frozen_string_literal: true

module Import
  module Solvers
    # Shared helper methods for building Phase 1 session/pool/city hash structures.
    # Used by Phase1Solver (auto-fill on build) and Phase1SessionRescanner (rescan from meeting).
    #
    module SessionHashBuilder
      # Builds a Phase 1 session hash from a GogglesDb::MeetingSession instance.
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

      # Builds a Phase 1 pool hash from a GogglesDb::SwimmingPool and its City.
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

      # Builds a Phase 1 city hash from a GogglesDb::City instance.
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

      # Builds a minimal Phase 1 session hash from parsed date fields and venue/pool info,
      # attempting to find existing pool/city in the DB.
      #
      # == Params:
      # - session_order: Integer
      # - scheduled_date: ISO date string (e.g. "2025-01-15")
      # - pool_name: String (venue name)
      # - address: String (venue address)
      # - pool_length: String ("25" or "50")
      #
      def build_session_hash_from_fields(session_order:, scheduled_date:, pool_name:, address:, pool_length:)
        pool_hash = find_and_build_pool_hash(pool_name, address, pool_length)

        {
          'id' => nil,
          'description' => "Sessione #{session_order}, #{scheduled_date}",
          'session_order' => session_order,
          'scheduled_date' => scheduled_date,
          'day_part_type_id' => nil,
          'swimming_pool' => pool_hash
        }
      end

      private

      # Attempts a DB lookup for the pool by name; falls back to a blank hash populated
      # with the raw fields extracted from the source data.
      def find_and_build_pool_hash(pool_name, address, pool_length)
        pool_type_id = pool_length.to_s.include?('50') ? GogglesDb::PoolType::MT_50_ID : GogglesDb::PoolType::MT_25_ID

        # Try to find an existing pool
        if pool_name.present?
          cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::SwimmingPool, { name: pool_name, pool_type_id: pool_type_id })
          if cmd&.successful?
            pool = cmd.result
            city = pool.city
            return build_pool_hash(pool, city)
          end
        end

        # Fallback: build a blank pool hash with whatever info we have
        city_hash = find_and_build_city_hash(address)
        {
          'id' => nil,
          'name' => pool_name,
          'nick_name' => nil,
          'address' => address,
          'pool_type_id' => pool_type_id,
          'lanes_number' => nil,
          'maps_uri' => nil,
          'plus_code' => nil,
          'latitude' => nil,
          'longitude' => nil,
          'city_id' => city_hash['id'],
          'city' => city_hash
        }
      end

      # Attempts to extract a city name from the address and find it in the DB.
      def find_and_build_city_hash(address)
        return {} if address.blank?

        city_name, _area, _remainder = Parser::CityName.tokenize_address(address)
        return {} if city_name.blank?

        cmd = GogglesDb::CmdFindDbEntity.call(GogglesDb::City, { name: city_name })
        return build_city_hash(cmd.result) if cmd&.successful?

        # Fallback: minimal hash with just the extracted name
        {
          'id' => nil,
          'name' => city_name,
          'area' => nil,
          'zip' => nil,
          'country' => nil,
          'country_code' => nil,
          'latitude' => nil,
          'longitude' => nil
        }
      end
    end
  end
end
