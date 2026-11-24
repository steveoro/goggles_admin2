# frozen_string_literal: true

module Sources
  #
  # = Sources::BaseController
  #
  # Common parent of the Sources area controllers (phase 15, /sources): the season shown (Sources::SeasonSelection,
  # 'season_id' param, remembered in the ops DB), the data root and its Sources::FileGuard, the page breadcrumbs and
  # the safe "return to" of the file actions. A refused path (Sources::FileGuard::Refused) never reaches a file
  # operation: it comes back as a warning.
  #
  class BaseController < ApplicationController
    before_action :set_season

    rescue_from Sources::FileGuard::Refused, with: :refused_path

    helper_method :season_id, :season_options, :sources_crumbs, :file_guard

    protected

    attr_reader :season_id

    def set_season
      @season_id = Sources::SeasonSelection.call(params[:season_id])
    end

    def season_options
      @season_options ||= Sources::SeasonSelection.options(data_root:, current: season_id)
    end

    def data_root = Sources.data_root

    def file_guard
      @file_guard ||= Sources::FileGuard.new(root: data_root)
    end

    def sources_index
      @sources_index ||= Sources::Index.new(season_id:, data_root:, guard: file_guard)
    end

    # Breadcrumbs: Import > Sources > <tab> (the tabs share one navigation item).
    def sources_crumbs(tab)
      [[I18n.t('shell.groups.import'), nil], [I18n.t('sources.nav'), sources_results_path(season_id:)], [I18n.t("sources.tabs.#{tab}"), nil]]
    end

    # The local Sources page to go back to after a file action (only '/sources/...' paths are accepted).
    def safe_return_to(fallback = sources_results_path(season_id:))
      value = params[:return_to].to_s
      value.start_with?('/sources/') && !value.start_with?('//') && value.exclude?("\n") ? value : fallback
    end

    # The safe "return to" page with the 'focus' param set to +name+ (its row is highlighted and scrolled to).
    def return_with_focus(fallback, name)
      uri = URI.parse(safe_return_to(fallback))
      query = Rack::Utils.parse_nested_query(uri.query).merge('focus' => name.to_s)
      uri.query = query.to_query
      uri.to_s
    rescue URI::InvalidURIError
      fallback
    end

    def refused_path(error)
      flash[:warning] = I18n.t("sources.files.refused.#{error.reason}", default: error.message)
      redirect_to(safe_return_to, status: :see_other)
    end
  end
end
