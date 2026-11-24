# frozen_string_literal: true

require 'fileutils'

# = CrawlerDataHousekeeping
#
# Specs that write SQL batch files (team managers, calendar links, backfill, commits...)
# use factory seasons, so they create folders such as 'crawler/data/results.new/518217'.
# The specs delete their files but the empty season folders stay behind, one set per run.
#
# At the end of every RSpec run this removes, directly under each results root, only the
# folders that are:
# - named with digits only (a season id);
# - completely empty;
# - not the id of a season present in the test DB (real seasons such as 242 are kept);
# - untouched for at least MIN_AGE seconds (a suite running at the same time may have
#   just created one and be about to write into it).
module CrawlerDataHousekeeping
  ROOTS = %w[results.new results.sent results.done].freeze
  MIN_AGE = 60 # seconds

  module_function

  # Returns the list of removed folder paths.
  def sweep!(data_root: Rails.root.join('crawler/data'), known_ids: nil, min_age: MIN_AGE, now: Time.zone.now)
    candidates = ROOTS.flat_map { |root| empty_season_folders(Pathname(data_root).join(root), min_age, now) }
    return [] if candidates.empty?

    known_ids ||= GogglesDb::Season.where(id: candidates.map { |path| path.basename.to_s.to_i }).pluck(:id)
    candidates.reject { |path| known_ids.include?(path.basename.to_s.to_i) }
              .select { |path| remove_if_still_empty(path) }
  end

  # Dir.rmdir never removes a folder with content: a file written since the scan keeps it.
  def remove_if_still_empty(path)
    Dir.rmdir(path)
    true
  rescue SystemCallError
    false
  end

  def empty_season_folders(root, min_age, now)
    return [] unless root.directory?

    root.children.select do |path|
      path.directory? && !path.symlink? && path.basename.to_s.match?(/\A\d+\z/) &&
        path.empty? && (now - path.mtime) >= min_age
    end
  end
end

RSpec.configure do |config|
  config.after(:suite) do
    removed = CrawlerDataHousekeeping.sweep!
    message = "\nHousekeeping: removed #{removed.size} empty test season folder(s) under crawler/data."
    config.reporter.message(message) if removed.any?
  rescue StandardError => e
    config.reporter.message("\nHousekeeping skipped (#{e.class}: #{e.message})")
  end
end
