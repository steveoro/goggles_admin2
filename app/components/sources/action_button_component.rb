# frozen_string_literal: true

module Sources
  #
  # = Sources::ActionButtonComponent
  #
  # One Sources::Index::RowAction: a link (GET), a one-button form (POST / DELETE, with its params as hidden fields
  # and an optional Turbo confirmation), or a disabled button. As a small button, or as a dropdown item (+menu+).
  #
  class ActionButtonComponent < ViewComponent::Base
    # - action: the RowAction; style: Bootstrap button style (buttons only);
    # - menu: render as a dropdown item; danger: red dropdown item (Delete).
    def initialize(action:, style: 'btn-outline-primary', menu: false, danger: false)
      super()
      @action = action
      @style = style
      @menu = menu
      @danger = danger
    end

    protected

    def css_class
      return ['dropdown-item', (@danger ? 'text-danger' : nil)].compact.join(' ') if @menu

      "btn btn-sm #{@style} text-nowrap"
    end

    def form_options
      options = { method: @action.http_method, params: @action.params, class: css_class, form_class: @menu ? nil : 'd-inline' }
      options[:form] = { data: { turbo_confirm: @action.confirm } } if @action.confirm.present?
      options
    end
  end
end
