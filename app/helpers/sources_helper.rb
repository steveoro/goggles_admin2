# frozen_string_literal: true

#
# = SourcesHelper
#
# View helpers of the Sources area (phase 15). The templates call these instead of naming the Sources::* constants:
# inside an ActionView template a bare 'Sources' resolves to ActionView::Template::Sources.
#
module SourcesHelper
  # The tabs of the Sources area for the season shown.
  def sources_tabs(active)
    render(Sources::TabsComponent.new(active:, season_id:))
  end

  # The season selector reloading +path+.
  def sources_season_selector(path)
    render(Sources::SeasonSelectorComponent.new(season_id:, options: season_options, path:))
  end

  # A Sources::FileTableComponent (see its params).
  def sources_file_table(**options)
    render(Sources::FileTableComponent.new(**options))
  end

  # The stored outcome of the last scan of a PDF.
  def sources_scan_result(scan, pdf_path)
    render(Sources::PdfScanResultComponent.new(scan:, pdf_path:))
  end

  # True when Sources::FilePolicy allows +action+ (:edit, :rename, :delete) on a Sources::FolderListing::Entry.
  def sources_file_allowed?(action, entry)
    Sources::FilePolicy.allowed?(action, entry.relative_path, size: entry.size.to_i)
  end

  def sources_read_only_folder?(relative_path) = Sources::FilePolicy.read_only_folder?(relative_path)

  # == Crawler tab (Sources::CrawlKinds)

  def sources_url_kinds = Sources::CrawlKinds::URL_KINDS

  def sources_calendar_sub_menus = Sources::CrawlKinds::CALENDAR_SUB_MENUS

  def sources_crawl_example(kind) = Sources::CrawlKinds::EXAMPLES[kind]

  def sources_crawl_site_link(kind) = Sources::CrawlKinds::SITE_LINKS[kind]

  def sources_year_text(season) = Sources::CrawlKinds.year_text_for(season)

  # == Other constants of the pages

  def sources_calendar_groups = Sources::Index::Calendars::GROUPS

  def sources_manifest_batch_size = Sources::ManifestsController::BATCH_SIZE

  def sources_folder_max_entries = Sources::FolderListing::MAX_ENTRIES

  def sources_pdf_scan_ping_id = PdfScanJob::NOTIFY_DOM_ID
end
