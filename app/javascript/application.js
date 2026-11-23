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
