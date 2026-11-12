# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::RowComponent
  #
  # One table row (+tr+) of the Season board for a SeasonBoard::Row: date, FIN meeting name,
  # place, linked local meeting (with MIR/MRR counts), state badge (+ flags), crawl/extraction
  # activity and the primary action (derived from <tt>row.next_action.kind</tt>).
  #
  # The POST actions (crawl, extract, link) take only the FIN event ID: the URLs are looked up
  # server-side. They are disabled while the row is busy (a crawl/extraction is queued or running).
  #
  class RowComponent < ViewComponent::Base
    # Bootstrap badge class for each state:
    STATE_CSS = {
      cancelled: 'badge-dark', sql_pending: 'badge-danger', in_review: 'badge-warning', results_ready: 'badge-primary',
      structure_ready: 'badge-info', manifest_pending: 'badge-info', committed_with_results: 'badge-success',
      structure_committed: 'badge-secondary', crawled_no_manifest: 'badge-light border',
      archived_unlinked: 'badge-warning', link_not_crawled: 'badge-light border', not_linked: 'badge-light border'
    }.freeze

    # Actions run through a POST of the FIN event ID: kind => path helper
    POST_ACTIONS = { crawl: :season_board_crawl_path, check_results: :season_board_crawl_path,
                     extract_manifest: :season_board_extract_path }.freeze

    # Data-Fix review step for each phase number: [route helper, params key]
    PHASE_STEPS = {
      1 => %i[review_sessions_path phase_v2], 2 => %i[review_teams_path phase2_v2],
      3 => %i[review_swimmers_path phase3_v2], 4 => %i[review_events_path phase4_v2],
      5 => %i[review_results_path phase5_v2]
    }.freeze

    # == Params:
    # - row: SeasonBoard::Row
    # - orphans: Array of SeasonBoard::DbIndex::CalendarInfo, targets of the "link" action
    #   (pass Builder::Result#link_candidates: the calendars without a FIN id yet)
    # - csrf_token: form authenticity token (the forms are rendered inside a component, which
    #   can't build it by itself); when +nil+ the forms are rendered without it
    def initialize(row:, orphans: [], csrf_token: nil)
      super()
      @row = row
      @orphans = orphans
      @csrf_token = csrf_token
    end

    protected

    attr_reader :row, :orphans, :csrf_token

    def action
      row.next_action
    end

    def action_kind
      action&.kind
    end

    def state_css
      STATE_CSS.fetch(row.state, 'badge-light border')
    end

    def state_label
      I18n.t("season_board.states.#{row.state}", phase: row.state_detail[:phase])
    end

    def state_tooltip
      I18n.t("season_board.state_tooltips.#{row.state}")
    end

    # Flags displayed as badges (:busy is shown by the activity badges, so it's skipped here)
    def shown_flags
      row.flags - [:busy]
    end

    def action_label
      I18n.t("season_board.actions.#{action_kind}", phase: action[:phase])
    end

    def post_action?
      POST_ACTIONS.key?(action_kind)
    end

    def post_action_path
      public_send(POST_ACTIONS.fetch(action_kind))
    end

    # Primary action path for the link-style actions (nil when unavailable)
    def link_action_path
      case action_kind
      when :review_results, :review_structure, :review_header
        review_sessions_path(file_path: action[:file_path], phase_v2: 1)
      when :resume_review
        helper, key = PHASE_STEPS.fetch(action[:phase].to_i, PHASE_STEPS[1])
        public_send(helper, { file_path: action[:file_path], key => 1 })
      when :push
        push_index_path
      end
    end

    def link_action?
      %i[review_results review_structure review_header resume_review push].include?(action_kind)
    end

    # True when the POST action has no FIN URL to work with
    def missing_url?
      post_action? && row.url.blank?
    end

    def show_secondary_link?
      orphans.any? && row.fin_event_id.present? && row.calendar_id.nil? && action_kind != :link && row.state != :cancelled
    end

    def orphan_label(orphan)
      [orphan.id, orphan.meeting_code, orphan.scheduled_date, orphan.meeting_name].filter_map(&:presence).join(' - ')
    end

    def meeting_text
      [row.meeting_description.presence, row.meeting_header_date].compact.join(' ')
    end

    # == Activity badges:

    # Returns an Array of Hashes { css:, text:, spin: } for the crawl/extract entries of the row
    def activity_items
      %i[crawl extract].filter_map { |kind| activity_item(kind, row.activity[kind]) }
    end

    def activity_item(kind, entry)
      return unless entry
      return { css: entry.running? ? 'badge-primary' : 'badge-info', text: busy_text(kind, entry), spin: entry.running? } if entry.busy?
      return { css: 'badge-warning', text: stuck_text(kind, entry), tooltip: I18n.t('season_board.activity.stuck_tooltip') } if entry.stale?
      return { css: 'text-danger', text: failed_text(entry), tooltip: entry.message } if entry.failed?

      return unless entry.done? && entry.finished_at

      { css: 'text-muted', text: I18n.t('season_board.activity.last_success', time: day_time(entry.finished_at),
                                                                              kind: I18n.t("season_board.activity.kinds.#{kind}")) }
    end

    def busy_text(kind, entry)
      origin = entry.origin == :auto ? 'auto' : 'manual'
      return I18n.t("season_board.activity.extract_#{entry.status}", time: hour(entry.started_at || entry.queued_at)) if kind == :extract

      I18n.t("season_board.activity.crawl_#{origin}_#{entry.status}", time: hour(entry.started_at || entry.queued_at))
    end

    # A queued/running entry past its staleness threshold (no longer busy, so the action is enabled again)
    def stuck_text(kind, entry)
      since = entry.started_at || entry.queued_at
      time = since && since.in_time_zone.to_date == Time.zone.today ? hour(since) : day_time(since)
      I18n.t("season_board.activity.#{kind}_stuck", time:)
    end

    def failed_text(entry)
      time = day_time(entry.finished_at || entry.last_timestamp)
      return I18n.t('season_board.activity.failed_no_message', time:) if entry.message.blank?

      I18n.t('season_board.activity.failed', time:, message: entry.message.to_s.truncate(120))
    end

    def hour(time)
      time ? time.in_time_zone.strftime('%H:%M') : '?'
    end

    def day_time(time)
      time ? time.in_time_zone.strftime('%d/%m %H:%M') : '?'
    end
  end
end
