# frozen_string_literal: true

module Normalize
  # = Normalize::CodedNames
  #
  #   - version:  7-0.10.60
  #   - author:   Steve A.
  #   - build:    20261017
  #
  # Scans the localhost DB for rows with a non-normalized coded name and prepares
  # a replayable, single-transaction SQL batch that can be pushed to the remote
  # production server using the Admin UI.
  #
  # This is the "export-only" counterpart of the engine-side
  # 'rake normalize:coded_names' task: it computes the very same values using
  # GogglesDb::Normalizers::CodedName but it *never* touches the local DB —
  # the prospective changes are logged as UPDATE statements instead.
  #
  # For each Meeting row, beside the +code+ column, the strategy detects also
  # fixable +edition+ and +edition_type_id+ values, folding all the changes into
  # a single UPDATE statement per row (see the engine task for the exact logic,
  # ported verbatim here).
  #
  # For each SwimmingPool row, a new +nick_name+ is proposed whenever the
  # normalized one differs; rows computing to an already existing +nick_name+
  # are skipped and reported in +duplicate_pool_ids+ (same as the engine task).
  #
  # The localhost DB is assumed to be in-sync with production, so the generated
  # statements reference the rows by their primary key.
  #
  # == Usage:
  #   normalizer = Normalize::CodedNames.new(limit: 0)
  #   normalizer.call
  #   normalizer.sql_log                     # => array of SQL statements & comments
  #   normalizer.single_transaction_sql_log  # => same, wrapped in START TRANSACTION..COMMIT
  #   normalizer.change_log                  # => human-readable list of prospective changes
  #   normalizer.duplicate_pool_ids          # => SwimmingPool IDs skipped for nick_name conflicts
  #
  class CodedNames # rubocop:disable Metrics/ClassLength
    attr_reader :limit, :sql_log, :change_log, :duplicate_pool_ids, :stats

    # Federation types having recurring ("championship") meetings whose
    # edition_type may need to be set when it was left as "none".
    CHAMPIONSHIP_FEDERATION_IDS = [
      GogglesDb::FederationType::FIN_ID,
      GogglesDb::FederationType::LEN_ID,
      GogglesDb::FederationType::FINA_ID
    ].freeze

    # == Params:
    # - <tt>:limit</tt> => when positive, only the first N rows of each domain
    #                     are processed (useful for trial runs; default: 0, all rows).
    #
    def initialize(limit: 0)
      @limit = limit.to_i
      @sql_log = []
      @change_log = []
      @duplicate_pool_ids = []
      @stats = {
        meetings_scanned: 0, meetings_updated: 0,
        pools_scanned: 0, pools_updated: 0
      }
      @meeting_log = []
      @pool_log = []
      @scanned = false
    end
    #-- -----------------------------------------------------------------------
    #++

    # Scans Meetings and SwimmingPools, collecting the prospective UPDATE statements.
    #
    # == Returns
    # The instance itself; safe to run only once.
    #
    def call
      return self if @scanned

      @scanned = true
      scan_meetings
      scan_pools
      assemble_log
      self
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the SQL log wrapped in a single transaction, as an array of SQL string statements.
    def single_transaction_sql_log
      Merge::Badge.start_transaction_log + @sql_log + Merge::Badge.end_transaction_log
    end
    #-- -----------------------------------------------------------------------
    #++

    private

    # == Scans ==============================================================

    # Ports the Meeting-scan logic from the engine-side 'normalize:coded_names' task,
    # emitting an UPDATE statement per row that needs any change instead of saving it.
    def scan_meetings
      domain = @limit.positive? ? GogglesDb::Meeting.limit(@limit) : GogglesDb::Meeting.all
      domain.includes(:federation_type,
                      meeting_sessions: { swimming_pool: %i[city pool_type] }).find_each do |meeting|
        @stats[:meetings_scanned] += 1
        changes = meeting_changes(meeting)
        next if changes.blank?

        @stats[:meetings_updated] += 1
        log_meeting_update(meeting, changes)
      end
    end

    # Returns the hash of changed columns for the given meeting (+edition_type_id+,
    # +edition+ and/or +code+, only the ones actually needing a fix), or an empty
    # hash when the row is already normalized.
    def meeting_changes(meeting) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      city = meeting.swimming_pools.present? ? meeting.swimming_pools.first&.city&.name : nil
      std_code = GogglesDb::Normalizers::CodedName.for_meeting(meeting.description, city)
      edition, _name_no_edition, edition_type_id = GogglesDb::Normalizers::CodedName.edition_split_from(meeting.description)
      # Ignore "NN Giorn(i|ate)" which isn't an edition number:
      edition = meeting.edition if meeting.description.starts_with?(/#{edition} giorn+/i)

      changes = {}
      # Fix edition_type for Federation Championships with recurring meetings:
      if CHAMPIONSHIP_FEDERATION_IDS.include?(meeting.federation_type&.id) &&
         meeting.edition_type_id != edition_type_id &&
         meeting.edition_type_id == GogglesDb::EditionType::NONE_ID
        changes['edition_type_id'] = edition_type_id
      end
      changes['edition'] = edition if edition != meeting.edition && edition.positive?

      if std_code != meeting.code
        if std_code.blank?
          @change_log << "-- Meeting ID #{meeting.id}: SKIPPED, blank computed code (was '#{meeting.code}')"
        elsif std_code.length > column_limit(GogglesDb::Meeting, 'code')
          @change_log << "-- Meeting ID #{meeting.id}: SKIPPED, computed code '#{std_code}' is too long " \
                         "(was '#{meeting.code}')"
        else
          changes['code'] = std_code
        end
      end
      changes
    end

    # Ports the SwimmingPool-scan logic from the engine-side task: skips rows whose
    # computed nick_name already exists on another pool, reporting them as warnings.
    def scan_pools
      domain = @limit.positive? ? GogglesDb::SwimmingPool.limit(@limit) : GogglesDb::SwimmingPool.all
      domain.includes(%i[city pool_type]).find_each do |swimming_pool|
        @stats[:pools_scanned] += 1
        log_pool_update(swimming_pool)
      end
    end

    # Logs a single UPDATE for the swimming pool row when its computed nick_name
    # differs from the stored one and is not already taken by another pool.
    def log_pool_update(swimming_pool) # rubocop:disable Metrics/AbcSize
      std_code = GogglesDb::Normalizers::CodedName.for_pool(
        swimming_pool.name, swimming_pool&.city&.name, swimming_pool.pool_type.code
      )
      return if std_code == swimming_pool.nick_name

      if std_code.blank?
        @change_log << "-- SwimmingPool ID #{swimming_pool.id}: SKIPPED, blank computed nick_name " \
                       "(was '#{swimming_pool.nick_name}')"
        return
      end
      if std_code.length > column_limit(GogglesDb::SwimmingPool, 'nick_name')
        @change_log << "-- SwimmingPool ID #{swimming_pool.id}: SKIPPED, computed nick_name '#{std_code}' is too long " \
                       "(was '#{swimming_pool.nick_name}')"
        return
      end
      if GogglesDb::SwimmingPool.exists?(nick_name: std_code)
        @duplicate_pool_ids << swimming_pool.id
        @change_log << "-- SwimmingPool ID #{swimming_pool.id}: SKIPPED, nick_name '#{std_code}' already exists " \
                       "(was '#{swimming_pool.nick_name}')"
        return
      end

      @stats[:pools_updated] += 1
      diff = "nick_name '#{swimming_pool.nick_name}' => '#{std_code}'"
      @change_log << "SwimmingPool ID #{swimming_pool.id}: #{diff}"
      @pool_log << "-- SwimmingPool ID #{swimming_pool.id} (#{swimming_pool.name}): #{diff}"
      @pool_log << SqlMaker.new(row: swimming_pool).log_update('nick_name' => std_code, 'updated_at' => nil)
      @pool_log << ''
    end

    # == SQL generation =====================================================

    # Returns the column length limit for the given model/column (or +INFINITY+
    # when the column has no length constraint).
    def column_limit(klass, column)
      klass.columns_hash[column]&.limit || Float::INFINITY
    end

    # Logs a single UPDATE for the meeting row with all its changed columns.
    def log_meeting_update(meeting, changes)
      diffs = changes.map { |col, val| "#{col} '#{meeting[col]}' => '#{val}'" }.join(', ')
      @change_log << "Meeting ID #{meeting.id}: #{diffs}"
      @meeting_log << "-- Meeting ID #{meeting.id} (#{meeting.description}): #{diffs}"
      @meeting_log << SqlMaker.new(row: meeting).log_update(changes.merge('updated_at' => nil))
      @meeting_log << ''
    end

    # Builds the final sql_log: header with stats + sections + warnings.
    def assemble_log
      @sql_log << "--\r\n-- *** normalize:coded_names -- coded names normalization batch ***\r\n--\r\n"
      @sql_log << "-- Meetings scanned.: #{@stats[:meetings_scanned]}, updated: #{@stats[:meetings_updated]}"
      @sql_log << "-- Pools scanned....: #{@stats[:pools_scanned]}, updated: #{@stats[:pools_updated]}"
      if @duplicate_pool_ids.present?
        @sql_log << "-- WARNING: already-existing coded names found for SwimmingPool IDs #{@duplicate_pool_ids.inspect} " \
                    '(skipped, manual fix needed)'
      end
      @sql_log << "--\r\n\r\n-- === Meetings ===\r\n"
      @sql_log.concat(@meeting_log)
      @sql_log << "\r\n-- === Swimming pools ===\r\n"
      @sql_log.concat(@pool_log)
    end
  end
end
