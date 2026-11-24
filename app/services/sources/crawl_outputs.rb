# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlOutputs
  #
  # Directory listing of the season folders a crawl may write (FOLDERS), taken before and after a SourceCrawlJob
  # run: the difference is the list of the new (or rewritten) files shown in the end-of-crawl toast and message.
  #
  # == Usage
  #   before = Sources::CrawlOutputs.listing(data_root, season_id)
  #   ... crawl ...
  #   Sources::CrawlOutputs.new_files(before, Sources::CrawlOutputs.listing(data_root, season_id), since:)
  #
  module CrawlOutputs
    # Folders (each with a <season> subfolder) written by the Node crawlers: result JSON (FIN LT2, Microplus, FICR,
    # Go&Swim LT4), calendar CSVs, the FIN result PDFs and the manifests.
    FOLDERS = %w[results.new calendar.new pdfs manifests].freeze
    # Files written by the crawler that are not sources.
    IGNORED = /\.(lock|tmp)\z/

    module_function

    # Hash of absolute path (String) => mtime (Time) of the files in the season folders.
    def listing(data_root, season_id)
      FOLDERS.each_with_object({}) do |folder, memo|
        dir = Pathname.new(data_root).join(folder, season_id.to_s)
        next unless dir.directory?

        dir.children.each do |child|
          memo[child.to_s] = child.mtime if child.file? && !IGNORED.match?(child.basename.to_s)
        end
      end
    end

    # Paths (sorted) of the files that are new in +after+, or were rewritten after +since+ (1 s tolerance).
    def new_files(before, after, since:)
      after.select { |path, mtime| !before.key?(path) || (mtime >= since - 1.second && mtime > before[path]) }.keys.sort
    end
  end
end
