# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::SeasonProgressComponent
  #
  # Season progress on the dashboard: the Season board state counts (SeasonBoard::Snapshot::Summary#state_counts)
  # as a stacked bar plus a legend; each segment and each legend chip opens the board filtered on that state.
  #
  class SeasonProgressComponent < ViewComponent::Base
    # Bootstrap 5 classes of each state (same hues as the board badges, theme-aware for the neutral ones).
    STATE_CSS = {
      cancelled: 'bg-dark-subtle text-dark-emphasis', sql_pending: 'text-bg-danger', prepare_failed: 'bg-danger-subtle text-danger-emphasis',
      needs_review: 'text-bg-warning', ready_to_commit: 'bg-success-subtle text-success-emphasis', in_review: 'text-bg-warning',
      results_ready: 'text-bg-primary', structure_ready: 'text-bg-info', manifest_pending: 'bg-info-subtle text-info-emphasis',
      committed_with_results: 'text-bg-success', structure_committed: 'text-bg-secondary',
      crawled_no_manifest: 'bg-secondary-subtle text-secondary-emphasis', archived_unlinked: 'bg-warning-subtle text-warning-emphasis',
      link_not_crawled: 'bg-primary-subtle text-primary-emphasis', not_linked: 'bg-body-secondary text-body-secondary'
    }.freeze
    NEUTRAL_CSS = 'bg-body-secondary text-body-secondary'

    # == Params:
    # - summary: SeasonBoard::Snapshot::Summary, or nil (no board summary yet);
    # - season: the board GogglesDb::Season, or nil.
    def initialize(summary:, season:)
      super()
      @summary = summary
      @season = season
    end

    protected

    attr_reader :summary, :season

    # [state, count] pairs with a count, in pipeline order (StateResolver::STATES).
    def segments
      @segments ||= begin
        counts = summary&.state_counts || {}
        SeasonBoard::StateResolver::STATES.filter_map { |state| [state, counts[state].to_i] if counts[state].to_i.positive? }
      end
    end

    def total
      @total ||= segments.sum(&:last)
    end

    def width(count)
      format('%.2f', count * 100.0 / total)
    end

    def state_css(state)
      STATE_CSS.fetch(state, NEUTRAL_CSS)
    end

    def state_label(state)
      state == :in_review ? t('season_board.states.in_review_chip') : t("season_board.states.#{state}")
    end

    def segment_title(state, count)
      t('dashboard.season_progress.segment', state: state_label(state), count:)
    end

    # Options of the legend chip linking to the board filtered on the state.
    def chip_options(state)
      { class: "badge rounded-pill text-decoration-none #{state_css(state)}", data: { turbo_frame: '_top', state_chip: state } }
    end

    def board_path(state)
      helpers.season_board_path(state:)
    end

    def as_of_text
      t('shell.status.as_of', time: l(summary.taken_at.localtime, format: :short)) if summary&.taken_at
    end
  end
end
