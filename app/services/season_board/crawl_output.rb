# frozen_string_literal: true

require 'fileutils'

module SeasonBoard
  #
  # = SeasonBoard::CrawlOutput
  #
  # Checks & tidies up what a single-meeting crawl (MeetingCrawlJob) has just written for a
  # FIN event id: only files modified at/after +since+ (the crawl start) and belonging to the
  # bases DiskIndex associates with the FIN id are ever considered.
  #
  # - No fresh LT2 source for the FIN id => :failed.
  # - Meeting already linked in the DB (see DbIndex):
  #   - fresh output with results => the re-downloaded manifest PDF is moved to manifests.done
  #     (the structure is already committed); the LT2 is kept for the results review;
  #   - result-free fresh output => the fresh LT2 & the re-downloaded manifest PDF are redundant
  #     and get deleted (unless the base also has an LT4 working copy or phase files).
  # - Unlinked meeting => files are left as they are (the board then shows the next step).
  #
  class CrawlOutput
    Outcome = Data.define(:status, :message, :results, :removed, :archived)

    def initialize(season_id:, fin_event_id:, since:, data_dir: DiskIndex.default_data_dir, db_index: nil)
      @season_id = season_id
      @fin_event_id = fin_event_id.to_s
      @since = since
      @data_dir = data_dir
      @db_index = db_index || DbIndex.new(season_id:)
    end

    # Returns an Outcome.
    def call
      entry = DiskIndex.new(season_id: @season_id, data_dir: @data_dir).for(@fin_event_id)
      sources = fresh_sources(entry)
      return Outcome.new(status: :failed, message: 'no output file found for this FIN id', results: false, removed: [], archived: []) if sources.empty?

      results = sources.any?(&:results?)
      return Outcome.new(status: :done, message: results ? 'results found' : 'no results yet', results:, removed: [], archived: []) unless linked?

      results ? archive_manifests(entry, sources) : remove_redundant(entry, sources)
    end

    private

    def linked?
      @db_index.calendar_for(@fin_event_id)&.linked? || false
    end

    def fresh_sources(entry)
      return [] unless entry

      entry.sources.select { |src| fresh?(src.lt2_path) }
    end

    def fresh?(path)
      path.present? && File.exist?(path) && File.mtime(path) >= @since
    end

    # Fresh manifest PDFs of the given bases.
    def fresh_manifests(entry, sources)
      bases = sources.map(&:base)
      entry.manifest_pdf_paths.select { |path| bases.include?(File.basename(path).sub(/\.pdf\z/i, '').delete_prefix('manifest-')) && fresh?(path) }
    end

    def archive_manifests(entry, sources)
      archived = fresh_manifests(entry, sources).map do |path|
        done_dir = DiskIndex.new(season_id: @season_id, data_dir: @data_dir).manifests_done_dir
        FileUtils.mkdir_p(done_dir)
        dest = done_dir.join(File.basename(path)).to_s
        FileUtils.mv(path, dest)
        dest
      end
      Outcome.new(status: :done, message: 'results found', results: true, removed: [], archived:)
    end

    def remove_redundant(entry, sources)
      removable = sources.select { |src| src.lt4_path.nil? && src.phase_paths.empty? }
      removed = removable.map(&:lt2_path) + fresh_manifests(entry, removable)
      FileUtils.rm_f(removed)
      message = removed.any? ? 'no results yet (redundant crawl output removed)' : 'no results yet'
      Outcome.new(status: :done, message:, results: false, removed:, archived: [])
    end
  end
end
