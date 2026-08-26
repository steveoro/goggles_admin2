# frozen_string_literal: true

# = GogglesCupHelper
#
# Helper methods used by the Goggles Cup preview/ranking views.
#
module GogglesCupHelper
  # Returns a lambda that builds a ranking/base-timings export URL for the cup loaded in +locals+.
  def goggle_cup_export_lambda(locals, default_export_type: 'ranking')
    goggle_cup = locals[:goggle_cup]
    team = locals[:team]

    lambda { |format:, export_type: default_export_type|
      compute_goggles_cup_preview_path(
        format: format,
        team_id: team&.id,
        goggle_cup_id: goggle_cup&.id,
        secondary_team_id: locals[:secondary_team_id],
        swimmer_ids: locals[:selected_swimmer_ids],
        no_duplicated_events: locals[:no_duplicated_events],
        export_type: export_type
      )
    }
  end

  # Returns the admin base-timings path for a stored cup loaded in +locals+, or +nil+ if none is selected.
  def goggle_cup_base_timings_path(locals)
    goggle_cup = locals[:goggle_cup]
    team = locals[:team]
    return nil unless goggle_cup&.id

    base_timings_goggles_cup_preview_path(team_id: team&.id, goggle_cup_id: goggle_cup&.id)
  end
end
