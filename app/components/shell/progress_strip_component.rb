# frozen_string_literal: true

module Shell
  #
  # = Shell::ProgressStripComponent
  #
  # The progress strip under the top bar, rendered once by the application layout inside the sticky header: the live
  # progress of the operator's own long requests (Data-Fix phase builds and rescans, the Phase 5 populate, "Verify
  # all", the category recompute), fed by ImportStatusChannel through the 'import-status' document event
  # (channels/import_status_channel.js, progress_strip_controller.js).
  #
  # - An overlay anchored under the header: showing or hiding it never moves the page, and it lets every click through
  #   to what it covers (pointer-events: none), except on its close button. No backdrop, never modal.
  # - The panel is hidden until a tick arrives; it hides on the operation's 'done', before Turbo caches the page, with
  #   its close button, and after SILENCE_DELAY ms without a message (a safety net for a lost 'done': every
  #   interactive request sends its 'done', see DataFix::BaseController#finish_progress).
  # - A polite live region, always rendered (a region revealed from `hidden` is often not announced), carries the
  #   scope and the message for screen readers; the visible texts are aria-hidden.
  # Background jobs never broadcast there (see Import::Progress).
  #
  class ProgressStripComponent < ViewComponent::Base
    DOM_ID = 'progress-strip'
    PANEL_ID = 'progress-strip-panel'
    # (ms) The only source of this value: rendered as the controller's silenceDelay value.
    SILENCE_DELAY = 60_000

    protected

    def root_attributes
      {
        id: DOM_ID, class: 'app-progress-strip',
        data: {
          controller: 'progress-strip', progress_strip_silence_delay_value: SILENCE_DELAY,
          action: 'import-status@document->progress-strip#update turbo:before-cache@document->progress-strip#reset'
        }
      }
    end

    def status_attributes
      {
        class: 'visually-hidden', role: 'status', 'aria-live' => 'polite', 'aria-atomic' => 'true',
        data: { progress_strip_target: 'status' }
      }
    end

    def panel_attributes
      { id: PANEL_ID, class: 'app-progress-strip-panel', hidden: true, data: { progress_strip_target: 'panel' } }
    end

    def bar_attributes
      {
        class: 'progress app-progress-strip-bar', role: 'progressbar', 'aria-label' => t('shell.progress_strip.label'),
        'aria-valuemin' => 0, 'aria-valuemax' => 100, 'aria-valuenow' => 0, data: { progress_strip_target: 'progress' }
      }
    end

    def close_attributes
      {
        type: 'button', class: 'btn-close app-progress-strip-close ms-auto', 'aria-label' => t('shell.progress_strip.close'),
        title: t('shell.progress_strip.close'), data: { action: 'progress-strip#dismiss' }
      }
    end
  end
end
