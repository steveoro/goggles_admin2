# frozen_string_literal: true

#
# = Switch components module
#
module Switch
  #
  # = Switch::ToggleFormComponent
  #
  # A stored boolean shown as a Bootstrap switch (<tt>.form-check.form-switch</tt>, <tt>role="switch"</tt>) inside a
  # small POST form: flipping it submits the form at once (toggle_submit_controller.js: +requestSubmit+, the switch is
  # disabled while the request is in flight and put back when the submit fails or the response is an error).
  # No inline handlers. Works with a Turbo Stream response (that usually replaces the whole form) and with a plain
  # redirect (Turbo follows it).
  #
  # The server-rendered position and disabled state are kept as Stimulus values (data-toggle-submit-checked-value,
  # -disabled-value): the controller puts the switch back to them on connect and before a Turbo cache snapshot, so a
  # page restored from the cache (Back) or by the browser never shows an unstored or stuck position
  # (autocomplete="off" too). The reason (disabled) or the help text is also an element pointed to by the checkbox's
  # aria-describedby (visually hidden, or shown as small text with +reason_visible+), besides the wrapper's title.
  #
  # The form posts a hidden <tt>name=unchecked_value</tt> followed by the checkbox <tt>name=checked_value</tt>, so the
  # param always carries the new state (the last value wins when the switch is on).
  #
  # == Params
  # - url: the POST target; name: the param of the new state; checked: the current state (Boolean);
  # - label: visible label (next to the switch); id: DOM id of the checkbox (the label points to it);
  # - params: Hash of extra hidden fields (e.g. the switch key, return_to);
  # - checked_value / unchecked_value: the values posted for on / off (default '1' / '0');
  # - disabled: true renders the switch read-only; reason: the tooltip saying why (shown on the wrapper, which keeps
  #   receiving the pointer events a disabled input loses); help: the tooltip of an enabled switch;
  # - turbo_frame: the form's data-turbo-frame ('_top' by default, nil for none);
  # - csrf_token: explicit authenticity token (for the forms rendered in components that pass one), else the default;
  # - form_class: extra CSS classes of the form; data: extra data attributes of the form;
  # - label_class: CSS classes of the label (default 'form-check-label');
  # - reason_visible: true shows the reason of a disabled switch as small text next to it (else visually hidden).
  #
  class ToggleFormComponent < ViewComponent::Base
    # rubocop:disable Metrics/ParameterLists
    def initialize(url:, name:, checked:, label:, id:, params: {}, checked_value: '1', unchecked_value: '0',
                   disabled: false, reason: nil, help: nil, turbo_frame: '_top', csrf_token: nil,
                   form_class: nil, data: {}, label_class: nil, reason_visible: false)
      # rubocop:enable Metrics/ParameterLists
      super()
      @url = url
      @name = name.to_s
      @checked = checked == true
      @label = label
      @id = id
      @params = params.to_h
      @checked_value = checked_value.to_s
      @unchecked_value = unchecked_value.to_s
      @disabled = disabled == true
      @reason = reason
      @help = help
      @turbo_frame = turbo_frame
      @csrf_token = csrf_token
      @form_class = form_class
      @data = data.to_h
      @label_class = label_class
      @reason_visible = reason_visible == true
    end

    protected

    attr_reader :url, :name, :label, :id, :params, :checked_value, :unchecked_value, :csrf_token

    def checked? = @checked

    def disabled? = @disabled

    # Tooltip of the wrapper (and description of the checkbox): the reason of a disabled switch, else the help text.
    def tooltip
      disabled? && @reason.present? ? @reason : @help.presence
    end

    # DOM id of the description element (nil without a description).
    def description_id
      "#{id}-description" if tooltip
    end

    # The reason of a disabled switch is shown as small text when asked; any other description is visually hidden.
    def description_css
      disabled? && @reason.present? && @reason_visible ? 'small text-body-secondary ms-2' : 'visually-hidden'
    end

    def form_options
      {
        # (an explicit token is rendered as a hidden field by the template, like SeasonBoard::RowComponent does)
        url:, method: :post, authenticity_token: (@csrf_token.present? ? false : nil),
        class: ['switch-toggle-form d-inline-flex align-items-center mb-0', @form_class].compact.join(' '),
        data: {
          controller: 'toggle-submit', turbo_frame: @turbo_frame, switch_state: checked? ? 'on' : 'off',
          toggle_submit_checked_value: checked?.to_s, toggle_submit_disabled_value: disabled?.to_s
        }.compact.merge(@data)
      }
    end

    def checkbox_options
      {
        id:, class: 'form-check-input', role: 'switch', disabled: disabled?, autocomplete: 'off',
        aria: { describedby: description_id }.compact,
        data: { action: 'change->toggle-submit#submit', toggle_submit_target: 'input' }
      }
    end

    def label_css
      ['form-check-label', @label_class].compact.join(' ')
    end
  end
end
