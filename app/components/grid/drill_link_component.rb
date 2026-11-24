# frozen_string_literal: true

module Grid
  #
  # = Grid::DrillLinkComponent
  #
  # A drill-down link of a grid row (phase 15): an icon (plus an optional visible text) leading to a related grid or
  # page, e.g. the badges of a swimmer or the Season board row of a meeting. The label is the tooltip and the
  # accessible name. Renders nothing without a path.
  #
  # == Usage (inside an html grid column):
  #   column(:drill, html: true, mandatory: true, order: false) do |asset|
  #     render(Grid::DrillLinkComponent.new(path: api_badges_path(badges_grid: { swimmer_id: asset.id }),
  #                                         icon: 'fa-id-badge', label: I18n.t('datagrid.drill.badges')))
  #   end
  #
  class DrillLinkComponent < ViewComponent::Base
    # == Params:
    # - path: target URL (nil renders nothing);
    # - icon: Font Awesome 6 solid icon name (e.g. 'fa-id-badge');
    # - label: tooltip and accessible name;
    # - text: optional visible text after the icon (e.g. a file name);
    # - kind: optional DOM hook (data-drill), e.g. 'badges'.
    def initialize(path:, icon:, label:, text: nil, kind: nil)
      super()
      @path = path
      @icon = icon
      @label = label
      @text = text
      @kind = kind
    end

    def render?
      @path.present?
    end

    protected

    def link_attributes
      {
        href: @path, class: link_class, 'aria-label' => @text.present? ? nil : @label,
        data: { bs_toggle: 'tooltip', bs_title: @label, drill: @kind }.compact
      }.compact
    end

    def link_class
      base = 'app-drill-link text-decoration-none text-nowrap'
      @text.present? ? "#{base} small font-monospace" : "#{base} px-1"
    end
  end
end
