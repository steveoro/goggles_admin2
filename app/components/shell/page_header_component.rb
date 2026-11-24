# frozen_string_literal: true

module Shell
  #
  # = Shell::PageHeaderComponent
  #
  # Page header: breadcrumbs, title (also used for the page <title>), optional row counter and subtitle,
  # plus an optional actions area on the right.
  #
  # == Usage (HAML):
  #   = render(Shell::PageHeaderComponent.new(title: t('dashboard.teams.title'), count: @domain_count)) do |header|
  #     - header.with_actions do
  #       = link_to(t('...'), some_path, class: 'btn btn-sm btn-outline-primary')
  #
  # == Slots:
  # - actions: buttons/links shown on the right of the title.
  #
  class PageHeaderComponent < ViewComponent::Base
    renders_one :actions

    # == Params:
    # - title: page title (also set as content_for(:title) unless the view already provided one);
    # - count: optional row counter (any Integer, 0 included; nil hides it);
    # - subtitle: optional one-line text below the title;
    # - crumbs: Array of [label, path] pairs; defaults to Shell::Navigation.breadcrumbs_for the current request.
    def initialize(title:, count: nil, subtitle: nil, crumbs: nil)
      super()
      @title = title
      @count = count
      @subtitle = subtitle
      @crumbs = crumbs
    end

    def before_render
      helpers.content_for(:title, @title.to_s) if @title.present? && !helpers.content_for?(:title)
      @crumbs = Shell::Navigation.breadcrumbs_for(helpers.controller_path, helpers.action_name, helpers.params) if @crumbs.nil?
    end
  end
end
