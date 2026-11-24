# frozen_string_literal: true

module DataFix
  #
  # = DataFix::IssueMarkers
  #
  # Which review cards need the operator ("needs you"), as issue codes per card: rendered as the `data-issue`
  # markers walked by the next/previous issue navigation (issue_nav_controller.js) and used by the "issues only"
  # toggles of Steps 1 and 4. Read only: every marker comes from the phase 09 rules, nothing is recomputed here.
  #
  # - Step 1: the verdict issues (DataFix::Verdicts::Phase1) placed on the meeting card or on the session card they
  #   concern, plus the Import::StructureValidator field errors of each card;
  # - Steps 2-3: DataFix::ReviewRules (the rows of the "review" filter);
  # - Step 4: the verdict issues (DataFix::Verdicts::Phase4) naming events (their 'details'), plus the unmatched
  #   events when the verdict reports them;
  # - Step 5: DataFix::IssueDetector (the programs of the issue filter), marked by the program cards themselves.
  #
  module IssueMarkers
    MEETING_CODES = %w[retry_needed fin_link_conflict meeting_not_fin_matched source_warnings].freeze

    module_function

    # Step 1: { meeting: [codes], sessions: { index => [codes] } }.
    def phase1(data:, structure_report:, verdict:)
      codes = issue_codes(verdict)
      meeting = MEETING_CODES.select { |code| codes.include?(code) }
      meeting.unshift('structure_invalid') if structure_report&.meeting_errors.present?
      sessions = Array(data['meeting_session']).each_with_index.with_object({}) do |(session, index), memo|
        list = []
        list << 'structure_invalid' if session_invalid?(structure_report&.session_errors&.[](index))
        list << 'new_session_in_existing_meeting' if codes.include?('new_session_in_existing_meeting') && data['id'].present? && session['id'].blank?
        memo[index] = list if list.any?
      end
      { meeting:, sessions: }
    end

    # Step 2: issue code of a team row (nil when the row needs nothing).
    def team(team)
      'teams_review' if DataFix::ReviewRules.team_in_review_filter?(team)
    end

    # Step 3: issue code of a swimmer row (nil when the row needs nothing).
    def swimmer(swimmer)
      'swimmers_review' if DataFix::ReviewRules.swimmer_in_review_filter?(swimmer)
    end

    # Step 4: one Array of codes per event of +events+ (the flattened events of the page, with their
    # '_session_order'), in the same order.
    def phase4(events:, verdict:)
      issues = Array(verdict&.issues).index_by { |issue| issue['code'] }
      by_key = %w[event_type_unresolved session_order_mismatch].index_with { |code| Array(issues.dig(code, 'details')).map(&:to_s) }
      missing_sessions = Array(issues.dig('session_missing', 'details')).map(&:to_i)
      Array(events).map do |event|
        codes = by_key.select { |_code, keys| keys.include?(event['key'].to_s) }.keys
        codes << 'session_missing' if missing_sessions.include?(event['_session_order'].to_i)
        codes << 'unmatched_events' if issues.key?('unmatched_events') && event['id'].blank? && event['meeting_event_id'].blank?
        codes
      end
    end

    def issue_codes(verdict)
      Array(verdict&.issues).reject { |issue| issue['level'] == 'info' }.map { |issue| issue['code'].to_s }
    end

    def session_invalid?(errors)
      return false unless errors.is_a?(Hash)

      %w[fields swimming_pool city].any? { |key| errors[key].present? || errors[key.to_sym].present? }
    end
  end
end
