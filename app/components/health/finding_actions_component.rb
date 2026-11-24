# frozen_string_literal: true

module Health
  #
  # = Health::FindingActionsComponent
  #
  # The actions of one data health finding: the Fix buttons of the maintenance operations first
  # (Maintenance::FixButtonComponent: they open the prefilled operation form, a dry run comes first; "Flag cancelled"
  # is the 'meeting.set_cancelled' operation), then the links of Health::FindingLinks#actions (Data-Fix review,
  # Outbox, Season board row, FIN results page); in compact mode (grid rows) small buttons plus "Details", without the
  # board link.
  #
  class FindingActionsComponent < ViewComponent::Base
    ICONS = { fix: Maintenance::FixButtonComponent::ICON, review: 'fa-wand-magic', push: 'fa-upload', board: 'fa-table-list',
              results_page: 'fa-arrow-up-right-from-square', season_start: 'fa-list-check' }.freeze

    # == Params:
    # - finding: Ops::HealthFinding; compact: true in the section grid;
    # - board_season_id: the Season board season ID (enables the board row link).
    def initialize(finding:, compact: false, board_season_id: nil)
      super()
      @finding = finding
      @compact = compact
      @board_season_id = board_season_id
    end

    protected

    attr_reader :finding, :compact

    def links
      @links ||= Health::FindingLinks.new(finding, board_season_id: compact ? nil : @board_season_id).actions
    end

    def button_class(_link)
      "btn #{'btn-sm' if compact} btn-outline-primary".squish
    end

    def link_options(link)
      options = { class: button_class(link), data: { turbo_frame: '_top', health_action: link.kind } }
      options[:title] = link.label if compact
      if link.external?
        options[:target] = '_blank'
        options[:rel] = 'noopener'
      end
      options
    end

    def icon(link) = ICONS.fetch(link.kind, 'fa-link')

    def details_options
      { class: 'btn btn-sm btn-outline-secondary', data: { turbo_frame: '_top', health_action: 'details' } }
    end
  end
end
