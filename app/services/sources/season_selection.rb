# frozen_string_literal: true

module Sources
  #
  # = Sources::SeasonSelection
  #
  # The season shown by the Sources pages: the 'season_id' request param when it names an existing season (then
  # remembered in the ops setting 'sources.season_id'), else the remembered one, else SeasonDefaults.default_season_id.
  # Without the ops DB nothing is remembered (the param or the default season is used).
  #
  module SeasonSelection
    # Folders holding one subfolder per season (their numeric names are offered in the selector).
    SEASON_FOLDERS = %w[results.new pdfs calendar.new calendar.done manifests manifests.done].freeze

    module_function

    # Returns the season id (Integer) to show, storing a valid +param+ as the new choice.
    def call(param)
      requested = valid_id(param)
      if requested
        Ops.safely { Ops::Setting.store!(SEASON_SETTING_KEY, requested) if Ops.available? }
        return requested
      end

      valid_id(stored) || SeasonDefaults.default_season_id.to_i
    end

    # The remembered season id, or nil.
    def stored
      Ops.safely { Ops.available? ? Ops::Setting.fetch(SEASON_SETTING_KEY) : nil }
    end

    # Selector options ([label, id] pairs, newest first): the seasons having a folder in the data root, plus the
    # +current+ one and the default one.
    def options(data_root:, current:)
      ids = folder_season_ids(data_root) | [current.to_i, SeasonDefaults.default_season_id.to_i]
      GogglesDb::Season.where(id: ids.select(&:positive?)).order(begin_date: :desc, id: :desc)
                       .map { |season| ["#{season.id} – #{season.description}", season.id] }
    end

    # Numeric subfolder names of the SEASON_FOLDERS (Integers).
    def folder_season_ids(data_root)
      SEASON_FOLDERS.flat_map do |folder|
        dir = Pathname.new(data_root).join(folder)
        dir.directory? ? dir.children.select(&:directory?).map { |child| child.basename.to_s } : []
      end.grep(/\A\d+\z/).map(&:to_i).uniq
    end

    def valid_id(value)
      id = value.to_s.match?(/\A\d+\z/) ? value.to_i : 0
      id.positive? && GogglesDb::Season.exists?(id:) ? id : nil
    end
  end
end
