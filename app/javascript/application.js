// Bootstrap 4 → 5 data-* attribute shim: must run first (see bs4_compat.js)
import "bs4_compat"

// Bootstrap 5 (data API + components); controllers import { Modal, Collapse, Tooltip, ... } directly
import * as bootstrap from "bootstrap"
window.bootstrap = bootstrap

import { Turbo } from "@hotwired/turbo-rails"
// Turbo 8 (bundled by turbo-rails 2.0.23): show the progress bar after 150 ms (default: 500 ms)
Turbo.config.drive.progressBarDelay = 150
import "controllers"
import "channels"
