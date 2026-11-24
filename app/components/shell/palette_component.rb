# frozen_string_literal: true

module Shell
  #
  # = Shell::PaletteComponent
  #
  # The command palette (phase 15): a Bootstrap modal (<tt>#command-palette</tt>, no fade: it opens and closes at once)
  # driven by palette_controller.js. Opened by Ctrl+K / Cmd+K or by the top bar trigger (Shell::PaletteTriggerComponent).
  #
  # - The navigation entries (every Shell::Navigation item) are embedded as JSON and matched in the browser;
  # - meetings, teams, swimmers and Data-Fix sessions come from <tt>GET /palette/search?q=</tt> (Shell::PaletteController,
  #   local DB and files only). An API-offline session lists only the offline pages and searches nothing else.
  #
  # Rendered once by the application layout, at the body level (outside the sticky top bar, whose stacking context
  # would put the modal under its backdrop). Renders no API call.
  #
  class PaletteComponent < ViewComponent::Base
    # DOM id of the modal (the trigger targets it)
    DOM_ID = 'command-palette'

    # Typed characters before the local search starts (Shell::PaletteSearch::MIN_QUERY)
    MIN_CHARS = Shell::PaletteSearch::MIN_QUERY

    # == Params:
    # - offline: true for an API-offline session.
    def initialize(offline: false)
      super()
      @offline = offline
    end

    protected

    def entries_json
      Shell::Navigation.palette_entries(offline: @offline).to_json
    end

    # (blank in an API-offline session: no entity search)
    def search_url
      @offline ? '' : helpers.palette_search_path
    end

    def root_data
      {
        controller: 'palette', action: 'keydown@window->palette#hotkey',
        palette_entries_value: entries_json, palette_search_url_value: search_url, palette_min_chars_value: MIN_CHARS
      }
    end

    def status_attributes
      {
        id: "#{DOM_ID}-status", role: 'status', 'aria-live' => 'polite',
        data: { palette_target: 'status', searching: t('shell.palette.searching') }
      }
    end

    def input_attributes
      {
        type: 'text', id: "#{DOM_ID}-input", class: 'form-control', autocomplete: 'off', spellcheck: 'false',
        role: 'combobox', 'aria-expanded' => 'true', 'aria-autocomplete' => 'list', 'aria-controls' => "#{DOM_ID}-results",
        'aria-label' => t('shell.palette.label'), placeholder: t('shell.palette.placeholder'),
        data: { palette_target: 'input', action: 'input->palette#filter keydown->palette#navigate' }
      }
    end
  end
end
