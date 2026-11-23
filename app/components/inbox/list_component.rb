# frozen_string_literal: true

module Inbox
  #
  # = Inbox::ListComponent
  #
  # The "Needs you" list: the shown items of an Inbox::Builder::Result (Inbox::ItemComponent each), an empty state,
  # and one "N more: <source>" line per source whose items were left out by the cap (linking to the source's
  # +more_path+, when it has one).
  #
  class ListComponent < ViewComponent::Base
    # == Params:
    # - result: an Inbox::Builder::Result;
    # - now: reference time.
    def initialize(result:, now: Time.current)
      super()
      @result = result
      @now = now
    end

    protected

    attr_reader :result

    # Array of [label, count, path or nil] for the sources with hidden items.
    def more_lines
      result.hidden.map do |source_key, count|
        source = Registry.sources.find { |klass| klass.key == source_key }
        path = source.respond_to?(:more_path) ? source.more_path : nil
        [t("inbox.sources.#{source_key}", default: source_key.to_s.humanize), count, path]
      end
    end
  end
end
