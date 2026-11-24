# frozen_string_literal: true

# Pin npm packages by running ./bin/importmap
#
# Every third-party module is vendored under vendor/javascript (no CDN at runtime), each with its
# LICENSE file alongside. Pins without a "# @x.y.z" comment are hand-vendored single-file bundles
# (see their notes): re-fetch those by hand when upgrading. Avoid `bin/importmap pristine` and
# `bin/importmap pin|update` on bootstrap, tom-select or chart.js: they would (re)download files
# that can't be served alone (Popper's lib/index.js, chart.js chunks, the tom-select UMD build).

pin 'application'
pin '@hotwired/turbo-rails', to: 'turbo.min.js'
pin '@hotwired/stimulus', to: 'stimulus.min.js'
pin '@hotwired/stimulus-loading', to: 'stimulus-loading.js'
pin '@rails/actioncable', to: 'actioncable.esm.js'
pin_all_from 'app/javascript/controllers', under: 'controllers'
pin_all_from 'app/javascript/channels', under: 'channels'
# Shared modules of the Stimulus controllers (e.g. lib/form_fields, the DOM helpers of the Data-Fix card controllers)
pin_all_from 'app/javascript/lib', under: 'lib'

# Bootstrap 4 → 5 compatibility shim (copies BS4 data-* attributes to their BS5 names; imported first)
pin 'bs4_compat', to: 'bs4_compat.js'

# Bootstrap 5.3 (dist/js/bootstrap.esm.js; the download URL is in the vendored file header).
pin 'bootstrap' # @5.3.9
# Popper 2.11.8: a single-file ESM bundle (source URL in the file header). The package's
# lib/index.js, which the pin command downloads, only re-exports sibling files.
pin '@popperjs/core', to: '@popperjs--core.js' # v2.11.8, single-file ESM bundle

# Third-party libraries used by Stimulus controllers.
# chart.js 4.4.4 — used by chart_api_controller (`import { Chart } from 'chart.js/auto'`):
# a single-file ESM bundle of chart.js/auto (the package's dist/chart.js imports
# relative chunks); its @kurkle/color import is rewritten to the pin below.
pin 'chart.js/auto', to: 'chart.js--auto.js' # v4.4.4, single-file ESM bundle
pin '@kurkle/color', to: '@kurkle--color.js' # @0.3.4

# tom-select 2.3.1 — replaces select2 and easyAutocomplete. The package's ESM build
# (dist/esm/tom-select.complete.js); the pin command would download the UMD build instead.
pin 'tom-select', to: 'tom-select.js' # v2.3.1, dist/esm/tom-select.complete.js

# CodeMirror 6 — JSON editor (replaces jsoneditor), used by grid_edit_controller.
# Single esbuild bundle vendored at vendor/javascript/codemirror-json.js:
# CDN '+esm' pins of individual @codemirror/* packages each resolve their own
# cross-package dependencies, loading duplicate @codemirror/state instances and
# breaking extension instanceof checks ("Unrecognized extension value...").
# To rebuild: bundle a shim re-exporting @codemirror/{view,state,commands,search,
# language,autocomplete,lang-json} with esbuild --bundle --format=esm --minify.
pin 'codemirror-json', to: 'codemirror-json.js'
