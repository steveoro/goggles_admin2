# frozen_string_literal: true

module Sources
  class Index
    #
    # = Sources::Index::Calendars
    #
    # Rows of the Calendars tab, in groups: the original calendar CSVs of 'calendar.new/<season>' (written by the FIN
    # calendar crawl), the '-sel-' subsets written by "Crawl selected", the '-skip' leftovers of a crawl, and the
    # files already crawled ('calendar.done/<season>'). The CSVs still in calendar.new open the meeting selection
    # page; "Crawl all" queues a calendar CSV crawl (SourceCrawlJob, kind calendar_results).
    #
    class Calendars
      GROUPS = %i[originals subsets leftovers done].freeze
      SUBSET_REGEXP = /-sel-\d/
      LEFTOVER_REGEXP = /-skip\.csv\z/i

      def initialize(index)
        @index = index
      end

      # Hash of group => Array of Row (every group present, possibly empty).
      def groups
        pending = @index.files_in('calendar.new', '*.csv').map { |path| [group_for(path), pending_row(path)] }
        grouped = pending.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        grouped[:done] = @index.files_in('calendar.done', '*.csv').map { |path| @index.file_row(path, badges: rows_badge(path)) }
        GROUPS.index_with { |group| Array(grouped[group]).sort_by { |row| [-row.mtime.to_f, row.name] } }
      end

      private

      def group_for(path)
        name = path.basename.to_s
        if LEFTOVER_REGEXP.match?(name) then :leftovers
        elsif SUBSET_REGEXP.match?(name) then :subsets
        else :originals
        end
      end

      def pending_row(path)
        @index.file_row(path, badges: rows_badge(path), primary: select_action(path), extra: [crawl_action(path)])
      end

      def rows_badge(path)
        count = CrawlerCalendar::Sheet.new(path.to_s, season_id: @index.season_id, data_root: @index.data_root).row_count
        [Badge.new(label: I18n.t('sources.calendars.badges.rows', count:), tone: 'secondary')]
      rescue StandardError
        [Badge.new(label: I18n.t('sources.calendars.badges.unreadable'), tone: 'danger')]
      end

      def select_action(path)
        RowAction.new(label: I18n.t('sources.calendars.actions.select'), icon: 'fa-list-check',
                      path: @index.url_helpers.sources_calendar_meetings_path(path: @index.relative(path)))
      end

      def crawl_action(path)
        RowAction.new(label: I18n.t('sources.calendars.actions.crawl_all'), icon: 'fa-spider', http_method: :post,
                      path: @index.url_helpers.sources_crawls_path,
                      params: { kind: 'calendar_results', season_id: @index.season_id, file_path: @index.relative(path) },
                      confirm: I18n.t('sources.calendars.actions.crawl_all_confirm'))
      end
    end
  end
end
