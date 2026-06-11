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

# jsoneditor — used by grid_edit_controller
pin 'jsoneditor', to: 'https://cdn.jsdelivr.net/npm/jsoneditor@9.10.4/dist/jsoneditor.min.js'
