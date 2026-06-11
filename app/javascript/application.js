import "@hotwired/turbo-rails"
import "controllers"
import "channels"

// DataFix helpers exposed as window.DataFix for inline event handlers
import * as DataFixHelpers from "data_fix_helpers"
window.DataFix = DataFixHelpers
