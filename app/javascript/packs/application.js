// This file is automatically compiled by Webpack, along with any other files
// present in this directory. You're encouraged to place your actual application logic in
// a relevant structure within app/javascript and only use these pack files to reference
// that code so it'll be compiled.

import '../controllers/index'

import Chart from 'chart.js/auto'
window.Chart = Chart

// Import DataFix helpers and expose to window for inline event handlers
import * as DataFixHelpers from '../data_fix_helpers'
window.DataFix = DataFixHelpers

// Styles:
import '../stylesheets/application'

require("@rails/ujs").start()
require("turbolinks").start()
require("@rails/activestorage").start()
require("channels")

// Before each page load:
// document.addEventListener('turbolinks:load', () => {
//   // DEBUG
//   console.log('turbolinks:load')
//   // (do something)
// })

// Uncomment to copy all static images under ../images to the output folder and reference
// them with the image_pack_tag helper in views (e.g <%= image_pack_tag 'rails.png' %>)
// or the `imagePath` JavaScript helper below.
//
// const images = require.context('../images', true)
// const imagePath = (name) => images(name, true)
