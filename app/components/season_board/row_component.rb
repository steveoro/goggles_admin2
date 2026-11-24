# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::RowComponent
  #
  # One table row (+tr+) of the Season board for a SeasonBoard::Row: date, FIN meeting name,
  # place, linked local meeting (with MIR/MRR counts), state badge (+ flags), crawl/extraction
  # activity and the primary action (derived from <tt>row.next_action.kind</tt>).
  #
  # The POST actions (crawl, extract, prepare, link) take only the FIN event ID: the URLs are looked up
  # server-side. They are disabled while the row is busy (a crawl/extraction/prepare is queued or running).
  # The action targets come from SeasonBoard::ActionPaths (shared with the pages summarising the board).
  #
  # Phase 10: a row with a Data-Fix source also offers "Prepare" (a DataFixPrepareJob, phases 1-5 only) and the
  # automation hold toggle (SECONDARY_PREPARE_STATES / #hold_toggle?); "Commit" only opens the commit summary.
  #
  class RowComponent < ViewComponent::Base
    # Neutral badge, following the light/dark theme (Bootstrap's .text-bg-light stays light in dark mode):
    NEUTRAL_CSS = 'bg-body-tertiary text-body-emphasis border'

    # Bootstrap 5 badge colour class for each state:
    STATE_CSS = {
      cancelled: 'text-bg-dark', sql_pending: 'text-bg-danger', prepare_failed: 'text-bg-danger', needs_review: 'text-bg-warning',
      ready_to_commit: 'text-bg-success', in_review: 'text-bg-warning', results_ready: 'text-bg-primary',
      structure_ready: 'text-bg-info', manifest_pending: 'text-bg-info', committed_with_results: 'text-bg-success',
      structure_committed: 'text-bg-secondary', crawled_no_manifest: NEUTRAL_CSS,
      archived_unlinked: 'text-bg-warning', link_not_crawled: NEUTRAL_CSS, not_linked: NEUTRAL_CSS
    }.freeze

    # Flags rendered as warning badges
    WARNING_FLAGS = %i[possible_unlinked_meeting].freeze

    # States offering a secondary "Prepare" button (the primary action stays the review / commit link).
    SECONDARY_PREPARE_STATES = %i[needs_review in_review results_ready structure_ready crawled_no_manifest].freeze

    # States whose source can be held (no automatic prepare) or released.
    HOLD_STATES = (SECONDARY_PREPARE_STATES + %i[prepare_failed ready_to_commit]).freeze

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
      STATE_CSS.fetch(row.state, NEUTRAL_CSS)
    end

    def state_label
      StateText.label(row.state, row.state_detail)
    end

    def state_tooltip
      I18n.t("season_board.state_tooltips.#{row.state}")
    end

    # Flags displayed as badges (:busy is shown by the activity badges, so it's skipped here)
    def shown_flags
      row.flags - [:busy]
    end

    # Badge class of a flag (warning flags stand out)
    def flag_css(flag)
      WARNING_FLAGS.include?(flag) ? 'text-bg-warning' : 'text-bg-secondary'
    end

    def action_label
      I18n.t("season_board.actions.#{action_kind}", phase: action[:phase])
    end

    def post_action?
      ActionPaths.post?(action_kind)
    end

    def post_action_path
      ActionPaths.post_path(action)
    end

    # Primary action path for the link-style actions (nil when unavailable)
    def link_action_path
      ActionPaths.link_path(action)
    end

    def link_action?
      ActionPaths.link?(action_kind)
    end

    # True when the POST action has no FIN URL to work with
    def missing_url?
      post_action? && row.url.blank?
    end

    # Source path of the row's next action (review, commit, prepare), or nil.
    def source_path
      action&.params&.dig(:file_path).presence
    end

    # True for a row offering the secondary "Prepare" button.
    def secondary_prepare?
      !row.busy? && source_path.present? && row.fin_event_id.present? && SECONDARY_PREPARE_STATES.include?(row.state)
    end

    # True for a row offering the automation hold toggle.
    def hold_toggle?
      !row.busy? && source_path.present? && row.fin_event_id.present? && HOLD_STATES.include?(row.state)
    end

    def held?
      row.flag?(:prepare_held)
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

    # Returns an Array of Hashes { css:, text:, spin: } for the crawl/extract/prepare entries of the row
    def activity_items
      ActivityLog::KINDS.filter_map { |kind| activity_item(kind, row.activity[kind]) }
    end

    def activity_item(kind, entry)
      return unless entry
      return { css: entry.running? ? 'text-bg-primary' : 'text-bg-info', text: busy_text(kind, entry), spin: entry.running? } if entry.busy?
      return { css: 'text-bg-warning', text: stuck_text(kind, entry), tooltip: I18n.t('season_board.activity.stuck_tooltip') } if entry.stale?
      return { css: 'text-danger', text: failed_text(entry), tooltip: entry.message } if entry.failed?

      return unless entry.done? && entry.finished_at

      { css: 'text-body-secondary', text: I18n.t('season_board.activity.last_success', time: day_time(entry.finished_at),
                                                                                       kind: I18n.t("season_board.activity.kinds.#{kind}")) }
    end

    def busy_text(kind, entry)
      origin = entry.origin == :auto ? 'auto' : 'manual'
      return I18n.t("season_board.activity.#{kind}_#{entry.status}", time: hour(entry.started_at || entry.queued_at)) if %i[extract prepare].include?(kind)

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
