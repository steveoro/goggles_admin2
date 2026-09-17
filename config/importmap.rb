# frozen_string_literal: true

# Pin npm packages by running ./bin/importmap

pin 'application'
pin '@hotwired/turbo-rails', to: 'turbo.min.js'
pin '@hotwired/stimulus', to: 'stimulus.min.js'
pin '@hotwired/stimulus-loading', to: 'stimulus-loading.js'
pin '@rails/actioncable', to: 'actioncable.esm.js'
pin_all_from 'app/javascript/controllers', under: 'controllers'
pin_all_from 'app/javascript/channels', under: 'channels'

# DataFix helpers (exposed as window.DataFix)
pin 'data_fix_helpers', to: 'data_fix_helpers.js'

# Third-party libraries used by Stimulus controllers.
# chart.js — used by chart_api_controller
pin 'chart.js', to: 'https://cdn.jsdelivr.net/npm/chart.js@4.4.4/+esm'
pin 'chart.js/auto', to: 'https://cdn.jsdelivr.net/npm/chart.js@4.4.4/auto/+esm'

# tom-select — replaces select2 and easyAutocomplete
pin 'tom-select', to: 'https://cdn.jsdelivr.net/npm/tom-select@2.3.1/dist/esm/tom-select.complete.min.js'

# CodeMirror 6 — JSON editor (replaces jsoneditor)
# NOTE: all @codemirror/@lezer pins must resolve to the *same* shared package versions as
# their own +esm-bundled dependencies (jsdelivr rewrites each file's imports to resolved-latest).
# Mismatched pins load duplicate module instances and break extension `instanceof` checks
# ("Unrecognized extension value in extension set"). Keep these in sync.
pin '@codemirror/view', to: 'https://cdn.jsdelivr.net/npm/@codemirror/view@6.43.12/+esm'
pin '@codemirror/state', to: 'https://cdn.jsdelivr.net/npm/@codemirror/state@6.7.5/+esm'
pin '@codemirror/lang-json', to: 'https://cdn.jsdelivr.net/npm/@codemirror/lang-json@6.0.2/+esm'
pin '@codemirror/commands', to: 'https://cdn.jsdelivr.net/npm/@codemirror/commands@6.11.1/+esm'
pin '@codemirror/language', to: 'https://cdn.jsdelivr.net/npm/@codemirror/language@6.12.4/+esm'
pin '@codemirror/search', to: 'https://cdn.jsdelivr.net/npm/@codemirror/search@6.7.2/+esm'
pin '@codemirror/autocomplete', to: 'https://cdn.jsdelivr.net/npm/@codemirror/autocomplete@6.20.3/+esm'
pin '@codemirror/lint', to: 'https://cdn.jsdelivr.net/npm/@codemirror/lint@6.9.7/+esm'
pin '@lezer/highlight', to: 'https://cdn.jsdelivr.net/npm/@lezer/highlight@1.2.3/+esm'
pin '@lezer/common', to: 'https://cdn.jsdelivr.net/npm/@lezer/common@1.5.2/+esm'
