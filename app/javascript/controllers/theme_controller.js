import { Controller } from "@hotwired/stimulus"

// Light/dark color mode toggle (Bootstrap 5.3 `data-bs-theme` on <html>).
// The choice is stored in the 'theme' cookie, which the layout reads (ApplicationHelper#current_theme).
//
// Targets: icon (optional) - its Font Awesome class mirrors the current mode.
export default class extends Controller {
  static targets = ["icon"]

  connect() {
    this.refresh()
  }

  toggle() {
    const next = this.current === "dark" ? "light" : "dark"
    document.documentElement.dataset.bsTheme = next
    document.cookie = `theme=${next}; path=/; max-age=31536000; SameSite=Lax`
    this.refresh()
  }

  get current() {
    return document.documentElement.dataset.bsTheme === "dark" ? "dark" : "light"
  }

  // The icon shows the mode a click switches to; the button's pressed state mirrors dark mode.
  refresh() {
    const dark = this.current === "dark"
    this.element.setAttribute("aria-pressed", dark ? "true" : "false")
    if (this.hasIconTarget) {
      this.iconTarget.classList.toggle("fa-moon", !dark)
      this.iconTarget.classList.toggle("fa-sun", dark)
    }
  }
}
