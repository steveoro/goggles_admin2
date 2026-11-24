# frozen_string_literal: true

module Shell
  #
  # = Shell::PaletteController
  #
  # Local search of the command palette (phase 15, palette_controller.js): meetings, teams, swimmers and Data-Fix
  # sessions matching the typed text (Shell::PaletteSearch: localhost DB and crawler/data only, no API call).
  # The sidebar pages are matched in the browser from the entries embedded by Shell::PaletteComponent.
  #
  class PaletteController < ApplicationController
    # GET /palette/search?q=<text>
    # JSON: <tt>{ results: [{ kind, kind_label, label, detail, path, icon }, ...] }</tt> (at most 20, none under 2 chars).
    def search
      results = Shell::PaletteSearch.new(params[:q]).results
      render(json: { results: results.map(&:to_h) })
    end
  end
end
