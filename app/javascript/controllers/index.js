// Load all the controllers within this directory and all subdirectories.
// Controller files must be named *_controller.js.

import { Application } from "stimulus"
import { definitionsFromContext } from "stimulus/webpack-helpers"

const application = Application.start()
const context = require.context("controllers", true, /_controller\.js$/)
application.load(definitionsFromContext(context))

// const context = require.context("controllers", true, /_controller\.js$/)
// const contextComponents = require.context('../../components', true, /_controller\.js$/)
// application.load(
//   definitionsFromContext(context).concat(
//     definitionsFromContext(contextComponents)
//   )
// )

// [Steve A.] For referencing Stimulus controllers for view-components all inside
// the 'app/javascript/components' path, name the context for "normal" Stimulus
// controllers and add another context just for the components' controllers.
//
// Then, load into the application both contexts appended together:
//
// const context = require.context('.', true, /\.js$/)
// const contextComponents = require.context('../../components', true, /_controller\.js$/)
// application.load(
//   definitionsFromContext(context).concat(
//     definitionsFromContext(contextComponents)
//   )
// )
