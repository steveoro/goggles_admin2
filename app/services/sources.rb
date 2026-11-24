# frozen_string_literal: true

#
# = Sources
#
# The Sources area (phase 15, /sources): one season-aware place for the files under 'crawler/data' (results JSON,
# calendars, pending manifests, PDFs, every other data folder) and for the manual crawls, PDF scans and manifest
# extractions, which all run as tracked background jobs (SourceCrawlJob, PdfScanJob, ManifestExtractJob).
#
# - Sources::CrawlKinds / Sources::CrawlRequest: the manual crawl kinds and their URL checks;
# - Sources::Index: the rows of each tab for a season; Sources::SeasonSelection: the chosen season;
# - Sources::FileGuard: every file operation resolves its paths through it (never outside 'crawler/data');
# - Sources::FileEditor: the JSON-validated, atomic save of the file editor (phase files get the edit marker).
#
module Sources
  # Ops::Setting key of the season chosen on the Sources pages.
  SEASON_SETTING_KEY = 'sources.season_id'

  module_function

  # Base 'crawler/data' folder (the Season board one: specs stub SeasonBoard::DiskIndex.default_data_dir).
  def data_root
    Pathname.new(SeasonBoard::DiskIndex.default_data_dir)
  end
end
