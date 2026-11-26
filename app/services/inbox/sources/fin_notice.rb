# frozen_string_literal: true

module Inbox
  module Sources
    #
    # = Inbox::Sources::FINNotice
    #
    # The FIN calendar changes the automation acknowledged with something to note but nothing to crawl (0.10.103): one
    # notice item per 'fin.calendar_notice' event (FedernuotoWatch::Acknowledge: meetings removed from the page, meetings
    # new or changed without a link, a text-only change) of the last WINDOW, newest MAX_ITEMS, until dismissed.
    # "Dismiss" (POST federnuoto_watch/dismiss_notice) adds the event id to the ops setting DISMISSED_KEY; "Open board"
    # is the secondary link. No sticky alert is raised for these changes.
    #
    # Key: 'fin_notice:<event id>'. Needs the ops DB (the events live there).
    #
    class FINNotice < Inbox::Source
      EVENT_KIND = FedernuotoWatch::Acknowledge::NOTICE_EVENT
      DISMISSED_KEY = 'fin_watch.notice_dismissed_ids'
      WINDOW = 30.days
      MAX_ITEMS = 5
      # Dismissed ids kept in the setting (the newest ones).
      MAX_DISMISSED = 100
      MAX_NAMES = 3
      # Lists of the event data counted in the title (with the rows whose results FIN published while in review).
      PARTS = %w[removed without_link results_in_review].freeze

      def self.enabled?(context)
        context.ops_available?
      end

      # The dismissed event ids (Set of Integers; empty when unreadable).
      def self.dismissed_ids
        Ops.safely(Set.new) { Array(Ops::Setting.fetch(DISMISSED_KEY, [])).to_set(&:to_i) }
      end

      # Dismisses the notice event +event_id+; returns true when stored.
      def self.dismiss!(event_id)
        id = Integer(event_id.to_s, exception: false)
        return false unless id&.positive?

        Ops.safely(false) do
          next false unless Ops.available? && Ops::Event.exists?(id:, kind: EVENT_KIND)

          Ops::Setting.store!(DISMISSED_KEY, (dismissed_ids.to_a.sort + [id]).uniq.last(MAX_DISMISSED))
          true
        end
      end

      def items(context)
        dismissed = self.class.dismissed_ids
        events = Ops.safely([]) do
          Ops::Event.of_kind(EVENT_KIND).where(occurred_at: (context.now - WINDOW)..).recent.limit(MAX_ITEMS * 4).to_a
        end
        events.reject { |event| dismissed.include?(event.id) }.first(MAX_ITEMS).map { |event| item_for(event) }
      end

      private

      def item_for(event)
        data = event.data.is_a?(Hash) ? event.data : {}
        item(
          key: "fin_notice:#{event.id}", kind: :fin_notice, band: :notice, title: t(:title, parts: parts_of(data)),
          detail: detail_of(data), subject: { event_id: event.id },
          action: action(t(:dismiss), url_helpers.federnuoto_watch_dismiss_notice_path, http_method: :post, params: { id: event.id }),
          secondary_action: action(t(:open_board), url_helpers.season_board_path), since: event.occurred_at
        )
      end

      def parts_of(data)
        parts = PARTS.filter_map do |part|
          count = Array(data[part]).size
          t(part, count:) if count.positive?
        end
        parts << t(:text_only) if parts.empty?
        parts.join(', ')
      end

      def detail_of(data)
        names = PARTS.flat_map { |part| Array(data[part]) }.grep(Hash).filter_map { |row| row['name'].presence }
        return t(:detail_text_only) if names.empty?

        t(:detail, names: names.first(MAX_NAMES).join(', ') + (names.size > MAX_NAMES ? ', ...' : ''))
      end
    end
  end
end
