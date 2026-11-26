# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::FINChange
    #
    # The pending (not yet acknowledged) change of the FIN "Riepilogo Eventi" page detected by the watcher
    # (FedernuotoWatch::StateStore#pending_change) => "Open board". Acknowledging stays on the sticky alert.
    # 0.10.103: shown only while the alert is (FedernuotoWatch::Progress.alert_shown?: not while the automation found
    # nothing actionable in the change); with the progress of the automation, the detail tells how many of the changed
    # meetings with a link are already in the pipeline.
    #
    # Key: 'fin_change'.
    #
    class FINChange < Inbox::Source
      # Change lists counted (see FedernuotoWatchAlertComponent::SECTIONS).
      SECTIONS = %w[with_results added updated removed].freeze

      def items(context)
        change, progress = FedernuotoWatch::Progress.for_store
        return [] unless FedernuotoWatch::Progress.alert_shown?(change, progress)

        rows = SECTIONS.flat_map { |section| Array(change[section]) }
        [item(
          key: 'fin_change', kind: :fin_change, band: :notice, title: t(:title, count: rows.size), detail: detail_of(rows, progress),
          subject: {}, action: action(t(:open_board), url_helpers.season_board_path),
          since: parse_time(change['first_detected_at']) || parse_time(change['detected_at']) || context.now
        )]
      end

      private

      # The automation progress (with the automation on), else the first meeting names.
      def detail_of(rows, progress)
        return names_of(rows) unless progress.is_a?(Hash) && progress['automation'] == true && progress['actionable'].to_i.positive?

        t(:progress, done: progress['at_parity'].to_i, total: progress['actionable'].to_i)
      end

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
