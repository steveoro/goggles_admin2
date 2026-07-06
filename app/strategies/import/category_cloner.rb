# frozen_string_literal: true

module Import
  #
  # = Import::CategoryCloner
  #
  #   - version:  7-0.9.15
  #   - author:   Steve A.
  #
  # Generates a replayable SQL script for cloning missing CategoryType rows from a
  # source Season to a destination Season, optionally removing unwanted categories
  # from the destination.
  #
  # This strategy is *simulation-safe*: it never executes any DB changes. All SQL
  # statements are captured as text in #sql_log and can be written to a file by the
  # calling rake task for manual review and later execution on the production server.
  #
  # == Usage
  #   cloner = Import::CategoryCloner.new(src_season:, dest_season:, remove_codes: ['U25'])
  #   cloner.prepare
  #   cloner.sql_log  # => Array of SQL strings
  #
  class CategoryCloner
    attr_reader :sql_log, :log, :errors, :src_season, :dest_season

    # == Params
    # - +src_season+::  source GogglesDb::Season (*required*)
    # - +dest_season+:: destination GogglesDb::Season (*required*)
    # - +remove_codes+:: optional Array (or comma-separated String) of category codes
    #   to DELETE from the dest season before cloning.
    #
    def initialize(src_season:, dest_season:, remove_codes: nil)
      @src_season = src_season
      @dest_season = dest_season
      @remove_codes = parse_remove_codes(remove_codes)
      @sql_log = []
      @log = []
      @errors = []
    end

    # Prepares the SQL script by collecting all missing CategoryType INSERTs and
    # optional DELETE statements. Never touches the DB.
    # Check #errors after calling to detect validation failures.
    #
    def prepare
      return if valid_seasons? == false

      @log << "Cloning CategoryTypes from Season #{src_season.id} (#{src_season.header_year}) " \
              "=> Season #{dest_season.id} (#{dest_season.header_year})"

      existing_keys = collect_existing_dest_keys
      @log << "Destination season has #{existing_keys.size} existing CategoryTypes."

      inserted, skipped = prepare_inserts(existing_keys)
      @log << "INSERTs prepared: #{inserted}"
      @log << "Skipped (already in dest): #{skipped}"

      prepare_deletions if @remove_codes.any?

      wrap_in_transaction
    end
    #-- -------------------------------------------------------------------------
    #++

    private

    # Checks validity of constructor parameters; populates @errors on failure.
    def valid_seasons?
      @errors << 'Source season must be a valid GogglesDb::Season' unless valid_season?(@src_season)
      @errors << 'Destination season must be a valid GogglesDb::Season' unless valid_season?(@dest_season)
      @errors << 'Source and destination seasons must be different' if same_season?
      @errors.empty?
    end

    def valid_season?(season)
      season.is_a?(GogglesDb::Season) && season.valid?
    end

    def same_season?
      @src_season.is_a?(GogglesDb::Season) && @dest_season.is_a?(GogglesDb::Season) &&
        @src_season.id == @dest_season.id
    end

    # Returns a Set of [code, relay] tuples for all existing CategoryTypes in the dest season.
    def collect_existing_dest_keys
      GogglesDb::CategoryType
        .unscoped
        .where(season_id: dest_season.id)
        .pluck(:code, :relay)
        .to_set { |code, relay| [code, relay] }
    end

    # Iterates source CategoryTypes, generating INSERTs for those missing in dest.
    # Returns [inserted_count, skipped_count].
    def prepare_inserts(existing_keys)
      inserted = 0
      skipped = 0

      GogglesDb::CategoryType
        .unscoped
        .where(season_id: src_season.id)
        .find_each do |src_ct|
        key = [src_ct.code, src_ct.relay]
        if existing_keys.include?(key)
          skipped += 1
          next
        end

        new_ct = build_dest_category_type(src_ct)
        maker = SqlMaker.new(row: new_ct, force_id_on_insert: false)
        maker.log_insert
        @sql_log << maker.sql_log.last
        inserted += 1
      end

      [inserted, skipped]
    end

    # Builds a new (unsaved) CategoryType with source attributes minus ID/timestamps/lock,
    # re-pointed to the dest season.
    def build_dest_category_type(src_ct)
      GogglesDb::CategoryType.new(
        src_ct.attributes.except('id', 'lock_version', 'created_at', 'updated_at')
              .merge('season_id' => dest_season.id, 'created_at' => Time.current, 'updated_at' => Time.current)
      )
    end

    # Generates DELETE statements for categories matching @remove_codes in the dest season.
    def prepare_deletions
      to_remove = GogglesDb::CategoryType
                  .unscoped
                  .where(season_id: dest_season.id, code: @remove_codes)

      @log << "DELETEs prepared: #{to_remove.count} (codes: #{@remove_codes.join(', ')})"
      to_remove.find_each do |dest_ct|
        @sql_log << "DELETE FROM `category_types` WHERE `id` = #{dest_ct.id};"
      end
    end

    # Wraps the collected SQL statements in a transaction block.
    def wrap_in_transaction
      wrapped = ['SET AUTOCOMMIT = 0;', 'START TRANSACTION;', '']
      wrapped.concat(@sql_log)
      wrapped.push('', 'COMMIT;')
      @sql_log = wrapped
    end

    # Normalizes remove_codes into an Array of Strings.
    def parse_remove_codes(codes)
      return [] if codes.blank?

      Array(codes).flat_map { |c| c.to_s.split(',').map(&:strip) }.compact_blank
    end
  end
end
