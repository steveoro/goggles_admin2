# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::ActionButtonComponent
  #
  # One action button of the dashboard (inbox items, status rows): a link for a GET (a full URL opens in a new
  # tab), a one-button form for a POST or DELETE (with an optional Turbo confirm). Always navigates the whole page
  # (<tt>data-turbo-frame="_top"</tt>), since the dashboard zones are Turbo frames.
  #
  class ActionButtonComponent < ViewComponent::Base
    # == Params:
    # - action: an Inbox::Action, or a Hash { label:, path:, http_method:, params:, confirm: } (probe actions);
    # - css: button classes (default: a small primary button);
    # - icon: optional Font Awesome icon name (e.g. 'fa-play').
    def initialize(action:, css: 'btn btn-sm btn-primary', icon: nil)
      super()
      @action = action.is_a?(Hash) ? normalize(action) : action
      @css = css
      @icon = icon
    end

    def render?
      @action.present?
    end

    def call
      return link if @action.get?

      button_to(@action.path, method: @action.http_method, params: @action.params, class: @css, form_class: 'd-inline',
                              form: { data: { turbo_confirm: @action.confirm, turbo_frame: '_top' }.compact }) { content_for_button }
    end

    private

    def link
      options = { class: @css, data: { turbo_frame: '_top', turbo_confirm: @action.confirm }.compact }
      if @action.external?
        options[:target] = '_blank'
        options[:rel] = 'noopener'
      end
      link_to(@action.path, **options) { content_for_button }
    end

    def content_for_button
      icon = @icon ? tag.i(class: "fa-solid #{@icon} me-1", 'aria-hidden': 'true') : ''.html_safe
      external = @action.external? ? tag.i(class: 'fa-solid fa-arrow-up-right-from-square ms-1 small', 'aria-hidden': 'true') : ''.html_safe
      safe_join([icon, @action.label, external])
    end

    def normalize(hash)
      return nil if hash[:path].blank?

      Inbox::Action.new(label: hash[:label], path: hash[:path], http_method: hash[:http_method] || :get,
                        params: hash[:params] || {}, confirm: hash[:confirm])
    end
  end
end
