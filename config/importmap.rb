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
pin 'chart.js/auto', to: 'https://cdn.jsdelivr.net/npm/chart.js@4.4.4/+esm'

# tom-select — replaces select2 and easyAutocomplete
pin 'tom-select', to: 'https://cdn.jsdelivr.net/npm/tom-select@2.3.1/dist/esm/tom-select.complete.min.js'

# CodeMirror 6 — JSON editor (replaces jsoneditor)
pin '@codemirror/view', to: 'https://cdn.jsdelivr.net/npm/@codemirror/view@6.28.4/+esm'
pin '@codemirror/state', to: 'https://cdn.jsdelivr.net/npm/@codemirror/state@6.4.1/+esm'
pin '@codemirror/lang-json', to: 'https://cdn.jsdelivr.net/npm/@codemirror/lang-json@6.0.1/+esm'
pin '@codemirror/commands', to: 'https://cdn.jsdelivr.net/npm/@codemirror/commands@6.6.0/+esm'
pin '@codemirror/language', to: 'https://cdn.jsdelivr.net/npm/@codemirror/language@6.10.2/+esm'
pin '@codemirror/search', to: 'https://cdn.jsdelivr.net/npm/@codemirror/search@6.5.6/+esm'
pin '@codemirror/autocomplete', to: 'https://cdn.jsdelivr.net/npm/@codemirror/autocomplete@6.18.1/+esm'
pin '@codemirror/lint', to: 'https://cdn.jsdelivr.net/npm/@codemirror/lint@6.8.2/+esm'
pin '@lezer/highlight', to: 'https://cdn.jsdelivr.net/npm/@lezer/highlight@1.2.1/+esm'
pin '@lezer/common', to: 'https://cdn.jsdelivr.net/npm/@lezer/common@1.2.2/+esm'
