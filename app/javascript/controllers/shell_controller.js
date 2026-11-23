import { Controller } from '@hotwired/stimulus'

const COOKIE = 'sidebar'
const COLLAPSED_CLASS = 'app-shell--collapsed'
const STATUS_REFRESH_MS = 5 * 60 * 1000 // (status frame reload while the page stays open)

/**
 * = shell - StimulusJS controller =
 *
 * Bound to the layout's <body> (together with `tooltips`):
 * - toggleSidebar: collapses/expands the sidebar on large screens (icons only), storing the state in the
 *   'sidebar' cookie ('collapsed' / 'expanded') read server-side by ShellHelper#sidebar_collapsed?, so that
 *   the next page renders in the right state with no flash. (Below lg the sidebar is a Bootstrap offcanvas,
 *   opened through data-bs-toggle="offcanvas".)
 * - before a Turbo cache snapshot, closes the offcanvas sidebar so that a restored page never shows it open;
 * - reloads the top bar status frame (turbo-frame#shell-status) every 5 minutes while the page stays open.
 *
 * == Actions ==
 * - toggleSidebar
 */
export default class extends Controller {
  connect () {
    this.onBeforeCache = this.onBeforeCache.bind(this)
    document.addEventListener('turbo:before-cache', this.onBeforeCache)
    this.statusTimer = setInterval(() => this.reloadStatus(), STATUS_REFRESH_MS)
  }

  disconnect () {
    document.removeEventListener('turbo:before-cache', this.onBeforeCache)
    clearInterval(this.statusTimer)
  }

  toggleSidebar () {
    const shell = this.element.querySelector('.app-shell')
    if (!shell) return

    const collapsed = shell.classList.toggle(COLLAPSED_CLASS)
    document.cookie = `${COOKIE}=${collapsed ? 'collapsed' : 'expanded'}; path=/; max-age=31536000; SameSite=Lax`
    this.element.querySelectorAll('[aria-controls="app-sidebar"][data-action~="shell#toggleSidebar"]')
      .forEach((button) => button.setAttribute('aria-expanded', collapsed ? 'false' : 'true'))
  }

  onBeforeCache () {
    const sidebar = document.getElementById('app-sidebar')
    if (sidebar) sidebar.classList.remove('show', 'showing', 'hiding')
    document.querySelectorAll('.offcanvas-backdrop').forEach((node) => node.remove())
  }

  reloadStatus () {
    const frame = document.getElementById('shell-status')
    if (frame && frame.src && document.visibilityState === 'visible') frame.reload()
  }
}
