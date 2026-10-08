# frozen_string_literal: true

# Shared defaults for the data-import pipeline.
module SeasonDefaults
  module_function

  # Latest defined MASFIN (FIN Master championship) season, used as the fallback
  # when a source path carries no season-id directory. Replaces the previously
  # hardcoded season id 212, a stale leftover from when the default season id
  # was updated by hand each year.
  def default_season
    GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin)
  end

  def default_season_id
    default_season&.id
  end
end
