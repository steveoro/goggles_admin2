# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Builder
  #
  # Merges the items of the registered Inbox::Source classes into the "Needs you" list:
  #
  # 1. collects the items of each enabled source; a source that raises (in #items or in .enabled?) becomes ONE
  #    band-1 item ("Inbox source X failed: ...") instead of breaking the page;
  # 2. de-duplicates by +key+ (the most urgent item wins: lowest band, then oldest);
  # 3. de-duplicates by canonical +subject[:file_path]+ (same source file, whatever its LT2/LT4/phase-file
  #    spelling): a Season board item (BOARD_SOURCES) beats any other item, then the most urgent one wins;
  # 4. sorts by band, then oldest +since+ first, and keeps the first +max_items+; the rest is counted per source.
  #
  # == Result
  # - items: the shown Inbox::Item list; hidden: Hash of source key => count of the items left out;
  # - total: all the items after de-duplication.
  #
  class Builder
    MAX_ITEMS = 25

    # Sources whose items describe a Season board row: they win the de-duplication by file path.
    # (Phase 10 adds its pipeline state sources: ready to commit, needs review, prepare failed, extraction gave up.)
    BOARD_SOURCES = %i[board_rows unmatched_sources failed_jobs ready_to_commit needs_review prepare_failed extraction_gave_up].freeze

    # Built inbox.
    Result = Data.define(:items, :hidden, :total) do
      delegate :empty?, to: :items
      def hidden_count = hidden.values.sum
    end

    # == Params:
    # - sources: source classes (default: Inbox::Registry.sources);
    # - max_items: how many items are shown.
    def initialize(sources: Registry.sources, max_items: MAX_ITEMS)
      @sources = sources
      @max_items = max_items
    end

    # Returns the Result for the Inbox::Context.
    def call(context)
      items = @sources.flat_map { |source| collect(source, context) }
      sorted = dedup_by_file_path(dedup_by_key(items)).sort_by(&:sort_key)
      shown = sorted.first(@max_items)
      hidden = sorted.drop(@max_items).group_by(&:source).transform_values(&:size)
      Result.new(items: shown, hidden:, total: sorted.size)
    end

    # Canonical form of a Data-Fix file path: absolute, without the '-phaseN.json', '.json' and '-lt4'
    # suffixes, so that the LT2 source, its LT4 working copy and their phase files compare equal. Nil when blank.
    def self.canonical_file_path(path)
      return if path.blank?

      expanded = Pathname.new(path.to_s).expand_path(Rails.root).to_s
      expanded.sub(/-phase\d+\.json\z/, '').delete_suffix('.json').delete_suffix('-lt4')
    end

    private

    def collect(source, context)
      return [] unless source.enabled?(context)

      Array(source.new.items(context))
    rescue StandardError => e
      Rails.logger.warn("[Inbox::Builder] #{source.name} failed: #{e.class}: #{e.message}")
      [failure_item(source, e, context)]
    end

    def failure_item(source, error, context)
      key = Registry.key_for(source) || source.try(:key) || source.name
      Item.new(
        key: "inbox:#{key}:failed", source: key, kind: :source_failed, band: :failed,
        title: I18n.t('inbox.builder.source_failed', source: I18n.t("inbox.sources.#{key}", default: key.to_s.humanize),
                                                     error: "#{error.class}: #{error.message}".truncate(160)),
        action: Action.new(label: I18n.t('inbox.builder.reload'), path: Rails.application.routes.url_helpers.root_path),
        since: context.now
      )
    end

    # One item per key: the most urgent one (lowest band, then oldest).
    def dedup_by_key(items)
      items.group_by(&:key).values.map { |group| group.min_by(&:sort_key) }
    end

    # One item per canonical file path (items without a file path are all kept).
    def dedup_by_file_path(items)
      with_path, without_path = items.partition { |item| self.class.canonical_file_path(item.subject[:file_path]) }
      winners = with_path.group_by { |item| self.class.canonical_file_path(item.subject[:file_path]) }.values.map do |group|
        group.min_by { |item| [BOARD_SOURCES.include?(item.source) ? 0 : 1, *item.sort_key] }
      end
      without_path + winners
    end
  end
end
