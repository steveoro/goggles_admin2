# frozen_string_literal: true

module SeasonBoard
  class Snapshot
    #
    # = SeasonBoard::Snapshot::Row
    #
    # Read-only board row rebuilt from a stored summary (see SeasonBoard::Snapshot): the plain
    # subset of a SeasonBoard::Row, answering the same queries (#busy?, #flag?, #action?, #linked?),
    # so that SeasonBoard::ActionPaths and the board controller work with both.
    #
    # - fin_event_id, key, name, date_text, year, place, url, info: Strings (or nil);
    # - first_date, last_date: Date (or nil);
    # - state: Symbol (StateResolver::STATES); state_detail: Hash with Symbol keys (e.g. { phase: 3 });
    # - next_action: SeasonBoard::NextAction (kind Symbol, params Hash with Symbol keys) or nil;
    # - busy: true while a crawl/extraction is queued or running; flags: Array of Symbols (RowFlags::FLAGS);
    # - meeting_id, calendar_id: Integer (or nil).
    #
    Row = Data.define(
      :fin_event_id, :key, :name, :date_text, :year, :first_date, :last_date, :place, :url, :info,
      :state, :state_detail, :next_action, :busy, :flags, :meeting_id, :calendar_id
    ) do
      # Builds the Row from its stored Hash (String keys).
      def self.from_payload(hash)
        attributes = (Payload::ROW_ATTRIBUTES - %i[first_date last_date]).index_with { |attr| hash[attr.to_s] }
        attributes.merge!(
          first_date: parse_date(hash['first_date']), last_date: parse_date(hash['last_date']),
          state: hash['state'].to_s.to_sym, state_detail: (hash['state_detail'] || {}).deep_symbolize_keys,
          next_action: parse_action(hash['next_action']), busy: hash['busy'] == true, flags: Array(hash['flags']).map(&:to_sym)
        )
        new(**attributes)
      end

      def self.parse_action(hash)
        hash && NextAction.new(kind: hash['kind'].to_sym, params: (hash['params'] || {}).deep_symbolize_keys)
      end

      def self.parse_date(value)
        value.present? ? Date.iso8601(value.to_s) : nil
      rescue Date::Error
        nil
      end

      def busy? = busy
      def linked? = meeting_id.present?
      def flag?(flag) = flags.include?(flag.to_sym)
      def action?(kind) = next_action&.kind == kind&.to_sym
    end
  end
end
