# frozen_string_literal: true

module Import
  #
  # = StructureValidator
  #
  # Validates the meeting structure described by a Phase 1 data file without
  # persisting anything. Reuses the same lookup/normalization logic as the
  # phased committers (via their #prepare_model) to build draft or updated
  # existing models, then exposes per-attribute error maps and a flat error
  # list used to:
  #
  # - visually flag missing/invalid required fields in the Step 1 form
  # - gate the Step 5 commit button and the Phase 6 endpoint for
  #   "structure-only" commits (sources without result rows)
  #
  # Validity requires a valid meeting and at least one valid session
  # (sessions may omit the pool/city: swimming_pool is optional on
  # MeetingSession). Events are intentionally NOT checked: they are optional
  # and can be added on a later pass.
  #
  class StructureValidator
    # Session-level association errors produced by `validates_associated :meeting`
    # are omitted from the per-session map: the meeting is validated (and reported)
    # at its own level, and at commit time sessions run only after a valid meeting
    # has been persisted.
    SESSION_FIELDS_KEY = 'fields'
    SESSION_POOL_KEY = 'swimming_pool'
    SESSION_CITY_KEY = 'city'

    # Calendar-level errors map back to the meeting form fields that fix them.
    CALENDAR_TO_MEETING_ATTRS = {
      'meeting_code' => 'code',
      'scheduled_date' => 'header_date',
      'year' => 'dateYear1',
      'month' => 'dateMonth1'
    }.freeze

    def initialize(phase1_data:)
      @phase1_data = phase1_data || {}
      @stats = { errors: [] }
      @sql_log = []
      @validated = false
      @meeting_model = nil
      @calendar_model = nil
      @meeting_errors = {}
      @calendar_errors = {}
      @session_errors = {}
    end

    # True when meeting + sessions (+ nested pool/city when present) are valid
    # and at least one session exists.
    def valid?
      validate!
      @meeting_errors.empty? && @calendar_errors.empty? &&
        @session_errors.present? &&
        @session_errors.values.all? { |errors| session_entry_valid?(errors) }
    end

    # { 'attribute' => [msg, ...] } for the meeting card fields
    # (includes calendar-level errors mapped back to meeting fields)
    def meeting_errors
      validate!
      mapped_calendar_errors = @calendar_errors.transform_keys do |attribute|
        CALENDAR_TO_MEETING_ATTRS[attribute] || "calendar_#{attribute}"
      end
      @meeting_errors.merge(mapped_calendar_errors) { |_key, base, extra| base + extra }
    end

    # { session_index => { 'fields' => {attr => [msg]},
    #                      'swimming_pool' => {attr => [msg]} | nil,
    #                      'city' => {attr => [msg]} | nil } }
    def session_errors
      validate!
      @session_errors
    end

    # Flat list of "Entity: attribute message" strings for banners/flash.
    def error_messages
      validate!
      messages = []
      append_messages(messages, 'Meeting', @meeting_errors)
      append_messages(messages, 'Calendar', @calendar_errors)
      messages << 'Sessions: at least one session is required' if @session_errors.empty?
      @session_errors.each do |index, errors|
        append_messages(messages, "Session #{index + 1}", errors.fetch(SESSION_FIELDS_KEY, {}))
        append_messages(messages, "Session #{index + 1} SwimmingPool", errors[SESSION_POOL_KEY].to_h)
        append_messages(messages, "Session #{index + 1} City", errors[SESSION_CITY_KEY].to_h)
      end
      messages
    end

    private

    def append_messages(messages, label, errors)
      errors.each do |attribute, msgs|
        Array(msgs).each { |msg| messages << "#{label}: #{attribute.to_s.humanize} #{msg}" }
      end
    end

    def session_entry_valid?(errors)
      errors.fetch(SESSION_FIELDS_KEY, {}).empty? &&
        errors[SESSION_POOL_KEY].to_h.empty? &&
        errors[SESSION_CITY_KEY].to_h.empty?
    end

    # -----------------------------------------------------------------------

    def validate!
      return if @validated

      @validated = true
      @meeting_model = meeting_committer.prepare_model(@phase1_data)
      @meeting_model.valid?
      @meeting_errors = @meeting_model.errors.messages.stringify_keys

      @calendar_model = calendar_committer.prepare_model(@phase1_data.merge('meeting_id' => @meeting_model.id),
                                                         meeting: @meeting_model)
      @calendar_model.valid?
      @calendar_errors = @calendar_model.errors.messages.stringify_keys
      # meeting_code maps back to the meeting code field (already reported there)
      @calendar_errors.delete('meeting_code')

      sessions = Array(@phase1_data['meeting_session'])
      sessions.each_with_index do |session_hash, index|
        @session_errors[index] = validate_session(session_hash, index)
      end
    end

    # Validates a single session hash (plus nested pool/city when present)
    # without persisting. Mirrors the defaults applied by
    # Import::Committers::Main#normalize_session_attributes.
    def validate_session(session_hash, index)
      normalized = session_hash.deep_dup.with_indifferent_access
      normalized['session_order'] ||= index + 1
      normalized['day_part_type_id'] ||= GogglesDb::DayPartType::MORNING_ID
      normalized['meeting_id'] ||= @meeting_model.id

      session = meeting_session_committer.prepare_model(normalized)
      session.meeting ||= @meeting_model # satisfy belongs_to for draft meetings
      session.valid?
      field_errors = session.errors.messages.stringify_keys.except('meeting')

      { SESSION_FIELDS_KEY => field_errors }.merge(validate_session_bindings(session_hash))
    end

    # Validates the nested pool/city structures of a session, returning their
    # per-attribute error maps (empty hash when the session has no pool).
    def validate_session_bindings(session_hash)
      pool_hash = session_hash['swimming_pool']
      return {} if pool_hash.blank?

      result = {}
      city_hash = pool_hash['city']
      city = city_committer.prepare_model(city_hash) if city_hash.present?
      if city
        city.valid?
        result[SESSION_CITY_KEY] = city.errors.messages.stringify_keys
      end

      pool = swimming_pool_committer.prepare_model(pool_hash)
      pool.city ||= city if city
      pool.valid?
      result[SESSION_POOL_KEY] = pool.errors.messages.stringify_keys
      result
    end

    # -----------------------------------------------------------------------

    def meeting_committer
      @meeting_committer ||= Committers::Meeting.new(stats: @stats, logger: nil, sql_log: @sql_log)
    end

    def calendar_committer
      @calendar_committer ||= Committers::Calendar.new(stats: @stats, logger: nil, sql_log: @sql_log)
    end

    def meeting_session_committer
      @meeting_session_committer ||= Committers::MeetingSession.new(stats: @stats, logger: nil, sql_log: @sql_log)
    end

    def swimming_pool_committer
      @swimming_pool_committer ||= Committers::SwimmingPool.new(stats: @stats, logger: nil, sql_log: @sql_log)
    end

    def city_committer
      @city_committer ||= Committers::City.new(stats: @stats, logger: nil, sql_log: @sql_log)
    end
  end
end
