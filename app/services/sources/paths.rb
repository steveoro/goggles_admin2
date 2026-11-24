# frozen_string_literal: true

module Sources
  #
  # = Sources::Paths
  #
  # Where a data file is shown in the Sources area: the tab listing its folder (results.new, calendar.new or
  # calendar.done, pdfs, manifests) for its season, focused on the file; the Files tab (its folder) otherwise.
  #
  module Paths
    # Season folder => [tab route helper].
    TABS = {
      'results.new' => :sources_results_path, 'calendar.new' => :sources_calendars_path, 'calendar.done' => :sources_calendars_path,
      'pdfs' => :sources_pdfs_path, 'manifests' => :sources_manifests_path
    }.freeze

    module_function

    # Path of the tab showing +path+ (absolute, under +root+), with 'focus' = its basename and the anchor of its row;
    # nil for a blank path.
    def focus_path(path, season_id: nil, root: Sources.data_root)
      return if path.blank?

      relative = Pathname.new(path).relative_path_from(Pathname.new(root))
      parts = relative.each_filename.to_a
      folder, season = parts.first(2)
      helper = TABS[folder]
      if helper && parts.size == 3 && season.to_s.match?(/\A\d+\z/)
        url_helpers.public_send(helper, season_id: season.to_i, focus: parts.last, anchor: row_dom_id(relative.to_s))
      else
        url_helpers.sources_files_path(dir: parts[0..-2].join('/').presence, focus: parts.last, season_id:)
      end
    rescue ArgumentError
      nil
    end

    # DOM id of the Sources::FileTableComponent row of a file (path relative to the data root).
    def row_dom_id(relative_path)
      "sources-file-#{Digest::SHA1.hexdigest(relative_path.to_s)[0, 12]}"
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
    private_class_method :url_helpers
  end
end
