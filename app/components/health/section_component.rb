# frozen_string_literal: true

module Health
  #
  # = Health::SectionComponent
  #
  # One check section of the season page: a collapsible card whose header shows the check title, its open counts
  # per severity and the acknowledged / ignored counts, and whose body is the lazy 'health-section-<key>' Turbo frame
  # (Health::SectionsController: filters, bulk triage, findings grid). Open by default when something is open.
  #
  class SectionComponent < ViewComponent::Base
    # == Params:
    # - season: GogglesDb::Season; check: Health::Registry::Check;
    # - counts: { 'open' => { severity => n }, 'acknowledged' => n, 'ignored' => n } (or nil: nothing visible).
    def initialize(season:, check:, counts: nil)
      super()
      @season = season
      @check = check
      @counts = counts || { 'open' => {}, 'acknowledged' => 0, 'ignored' => 0 }
    end

    # DOM id of the section (also the anchor).
    def self.dom_id_for(check_key) = "health-section-#{check_key.to_s.parameterize}"

    # Frame id of the section body.
    def self.frame_id_for(check_key) = "#{dom_id_for(check_key)}-frame"

    protected

    attr_reader :season, :check, :counts

    def open_counts = counts['open'].to_h
    def open_total = open_counts.values.sum
    def open? = open_total.positive?

    # [severity, count] pairs with a count, most severe first.
    def severity_counts
      Ops::HealthFinding::SEVERITIES.filter_map { |severity| [severity, open_counts[severity]] if open_counts[severity].to_i.positive? }
    end

    def dom_id = self.class.dom_id_for(check.key)
    def frame_id = self.class.frame_id_for(check.key)

    # Lazy frame of the section body (reloaded by live_frames_controller.js).
    def frame_options
      { src: helpers.health_section_path(season.id, check.key), loading: :lazy, data: { 'live-frames-target': 'frame' } }
    end
  end
end
