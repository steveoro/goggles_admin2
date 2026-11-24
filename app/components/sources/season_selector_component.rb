# frozen_string_literal: true

module Sources
  #
  # = Sources::SeasonSelectorComponent
  #
  # GET form choosing the season of the Sources pages (submitted on change by sources_season_controller.js, with a
  # button for the no-JS case); the choice is remembered (Sources::SeasonSelection).
  #
  class SeasonSelectorComponent < ViewComponent::Base
    # - season_id: the current season; options: [label, id] pairs; path: the page to reload.
    def initialize(season_id:, options:, path:)
      super()
      @season_id = season_id
      @options = options
      @path = path
    end
  end
end
