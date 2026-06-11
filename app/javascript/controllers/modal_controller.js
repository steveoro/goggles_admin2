import { Controller } from '@hotwired/stimulus'

/**
 * = StimulusJS controller for auto-opening Bootstrap 4 modals =
 *
 * Bound to a Bootstrap-4 ".modal" element that gets injected into the page
 * via a Turbo Stream response. As soon as the controller connects, it shows
 * the modal using the global jQuery + Bootstrap bundle (both loaded via CDN).
 *
 * This replaces the legacy rails-ujs `.js.erb` pattern that used to call
 * `$('#some-modal').modal()` after an AJAX DOM replacement.
 *
 * == Usage ==
 * Add `data-controller="modal"` to the `.modal` root element rendered inside
 * the Turbo Stream target, e.g.:
 *
 *   .modal.fade{ id: 'file-actions-modal', 'data-controller' => 'modal' }
 *
 * Any element with `data-dismiss="modal"` keeps working as usual (Bootstrap).
 *
 * @author Steve A.
 */
export default class extends Controller {
  /**
   * Shows the bound modal when connected to the DOM.
   * Re-initializes any tooltips inside the modal body.
   */
  connect () {
    // eslint-disable-next-line no-undef
    $(this.element).modal('show')
    // Re-init tooltips for freshly injected modal content:
    // eslint-disable-next-line no-undef
    $(this.element).find('[data-toggle="tooltip"]').tooltip()
  }

  /**
   * Hides the modal when the controller is disconnected (e.g. element removed
   * by a subsequent Turbo Stream replacement).
   */
  disconnect () {
    // eslint-disable-next-line no-undef
    $(this.element).modal('hide')
    // Clean up any orphaned Bootstrap backdrop/body state left behind when the
    // modal element is detached by a subsequent Turbo Stream replacement:
    // eslint-disable-next-line no-undef
    $('.modal-backdrop').remove()
    // eslint-disable-next-line no-undef
    $('body').removeClass('modal-open').css('padding-right', '')
  }
}
