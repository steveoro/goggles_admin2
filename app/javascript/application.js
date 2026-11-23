// Bootstrap 4 → 5 data-* attribute shim: must run first (see bs4_compat.js)
import "bs4_compat"

// Bootstrap 5 (data API + components); controllers import { Modal, Collapse, Tooltip, ... } directly
import * as bootstrap from "bootstrap"
window.bootstrap = bootstrap

import "@hotwired/turbo-rails"
import "controllers"
import "channels"

// DataFix helpers exposed as window.DataFix for inline event handlers
import * as DataFixHelpers from "data_fix_helpers"
window.DataFix = DataFixHelpers

// TEMPORARY bridge, to be removed by the flash toasts (toast_controller, Phase 03 step 3):
// closes the non-sticky flash alerts rendered with the page after 3 seconds, as the removed
// popover_controller did.
document.addEventListener("turbo:load", () => {
  document.querySelectorAll(".flash-alert.alert:not(.flash-sticky)").forEach((alert) => {
    setTimeout(() => { if (alert.isConnected) bootstrap.Alert.getOrCreateInstance(alert).close() }, 3000)
  })
})
