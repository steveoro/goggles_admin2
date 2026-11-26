# frozen_string_literal: true

module Shell
  #
  # = Shell::StatusPillsComponent
  #
  # The top bar status pills (inside <tt>turbo-frame#shell-status</tt>, see Shell::StatusController), compacted:
  # - every probe :ok => one summary pill ("All OK") whose tooltip lists each probe and its detail;
  # - otherwise => one Shell::StatusPillComponent per probe not :ok (:warn, :error and :unknown, in registry order),
  #   then one summary pill "N OK" for the :ok ones (none when no probe is :ok).
  #
  # The summary pill (DOM id SUMMARY_ID) links to the dashboard System zone. Renders nothing without results.
  # Reads only the given results: no API call.
  #
  class StatusPillsComponent < ViewComponent::Base
    # DOM id of the summary pill (both "All OK" and "N OK").
    SUMMARY_ID = 'status-pill-all'
    # Bootstrap tooltip custom class: multi-line text (see shell/_layout.scss).
    TOOLTIP_CLASS = 'app-status-tooltip'

    # == Params:
    # - results: the SystemStatus::Result list, in display order (SystemStatus::Registry.results).
    def initialize(results:)
      super()
      @results = Array(results)
    end

    def render?
      @results.any?
    end

    protected

    attr_reader :results

    # Results needing attention (:warn, :error, :unknown), in display order.
    def attention_results
      @attention_results ||= results.reject(&:ok?)
    end

    def ok_results
      @ok_results ||= results.select(&:ok?)
    end

    def all_ok?
      attention_results.empty?
    end

    def summary?
      ok_results.any?
    end

    def summary_label
      all_ok? ? t('shell.status.summary.all_ok') : t('shell.status.summary.some_ok', count: ok_results.size)
    end

    def summary_aria_label
      key = all_ok? ? 'shell.status.summary.all_ok_aria' : 'shell.status.summary.some_ok_aria'
      t(key, count: ok_results.size)
    end

    # One line per :ok probe ("Label: detail"), then the dashboard hint.
    def summary_tooltip_text
      lines = ok_results.map { |result| "#{result.label}: #{result.detail.presence || t('shell.status.levels.ok')}" }
      lines << t('shell.status.summary.details')
      lines.join("\n")
    end

    def summary_css_classes
      variant = all_ok? ? 'text-bg-success' : 'bg-success-subtle text-success-emphasis border border-success-subtle'
      "badge rounded-pill app-status-pill app-status-summary #{variant}"
    end

    def summary_attributes
      {
        id: SUMMARY_ID, class: summary_css_classes, href: helpers.root_path(anchor: StatusPillComponent::DASHBOARD_SYSTEM_ANCHOR),
        'aria-label' => summary_aria_label,
        data: { bs_toggle: 'tooltip', bs_placement: 'bottom', bs_custom_class: TOOLTIP_CLASS, bs_title: summary_tooltip_text,
                status_level: 'ok', status_summary: all_ok? ? 'all' : 'rest', ok_count: ok_results.size, turbo_frame: '_top' }
      }
    end
  end
end
