# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::FINChange
    #
    # The pending (not yet acknowledged) change of the FIN "Riepilogo Eventi" page detected by the watcher
    # (FedernuotoWatch::StateStore#pending_change) => "Open board". Acknowledging stays on the sticky alert.
    #
    # Key: 'fin_change'.
    #
    class FINChange < Inbox::Source
      # Change lists counted (see FedernuotoWatchAlertComponent::SECTIONS).
      SECTIONS = %w[with_results added updated removed].freeze

      def items(context)
        change = FedernuotoWatch::StateStore.new.pending_change
        return [] unless change.is_a?(Hash) && change['detected_at'].present?

        rows = SECTIONS.flat_map { |section| Array(change[section]) }
        [item(
          key: 'fin_change', kind: :fin_change, band: :notice, title: t(:title, count: rows.size), detail: names_of(rows),
          subject: {}, action: action(t(:open_board), url_helpers.season_board_path),
          since: parse_time(change['first_detected_at']) || parse_time(change['detected_at']) || context.now
        )]
      end

      private

      # The first few meeting names of the change (or nil).
      def names_of(rows)
        rows.first(3).filter_map { |row| row['name'] if row.is_a?(Hash) }.join(', ').presence
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
