# frozen_string_literal: true

module Sources
  #
  # = Sources::TabsComponent
  #
  # The tabs of the Sources area (Results, Calendars, Manifests, PDFs, Crawler, Files), each keeping the chosen season.
  #
  class TabsComponent < ViewComponent::Base
    # Tab key => [route helper, Font Awesome icon]
    TABS = {
      results: %i[sources_results_path fa-file-lines], calendars: %i[sources_calendars_path fa-calendar],
      manifests: %i[sources_manifests_path fa-file-contract], pdfs: %i[sources_pdfs_path fa-file-pdf],
      crawler: %i[sources_crawler_path fa-spider], files: %i[sources_files_path fa-folder-tree]
    }.freeze

    # - active: the current tab key; season_id: the season shown.
    def initialize(active:, season_id:)
      super()
      @active = active.to_sym
      @season_id = season_id
    end

    protected

    def tabs
      TABS.map do |key, (helper, icon)|
        active = key == @active
        attributes = { href: helpers.public_send(helper, season_id: @season_id), id: "sources-tab-#{key}", class: active ? 'active' : nil,
                       'aria-current' => active ? 'page' : nil }
        { key:, icon:, label: t("sources.tabs.#{key}"), attributes: }
      end
    end
  end
end
