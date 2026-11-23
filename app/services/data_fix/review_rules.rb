# frozen_string_literal: true

module DataFix
  #
  # = DataFix::ReviewRules
  #
  # The one definition of "needs review" for the Data-Fix teams (Phase 2) and swimmers (Phase 3), used by the
  # review filters (DataFix::TeamsController, DataFix::SwimmersController), the verdicts (DataFix::Verdicts) and
  # the commit summary.
  #
  # A source is READY TO COMMIT when all five phase verdicts are 'clean' and fresh (none stale, blocked, review or
  # failed) and Import::CommitPreflight reports no errors (see DataFix::Pipeline::Summary#ready?).
  #
  # - Confidently new swimmer: swimmer_id nil, no fuzzy matches, gender, year of birth and category present.
  # - Confidently new team: team_id nil, no fuzzy matches, not 'similar_affiliated'.
  #   Confidently-new entities do NOT send a phase to review: they are listed by the commit summary.
  # - Review is required for:
  #   1. a meeting not matched by FIN event id and not saved by the operator (phase 1, see Verdicts::Phase1);
  #   2. a team with a candidate (nil id with fuzzy matches or 'similar_affiliated') or a Phase 3 conflict hint;
  #   3. a match under MATCH_BAR not confirmed by the operator; for swimmers also 'gender_guessed',
  #      'auto_assigned_from_secondary_match' and 'has_badge_duplicates'; a nil-id swimmer that is not
  #      confidently new;
  #   4. more than MAX_NEW_SWIMMER_SHARE new swimmers, or more than MAX_NEW_TEAM_SHARE new teams.
  # - 'confirmed' (set by saving a card) wins over everything: a confirmed row never counts as review.
  #   A rebuild drops it (fresh file).
  # - 'similar_on_team' stays out of the rules (it would flag almost every swimmer).
  #
  # The review FILTER of the pages shows the rows needing review plus the unconfirmed new (nil-id) rows, so that the
  # operator can still eyeball what will be created.
  #
  module ReviewRules
    MATCH_BAR = 89.0
    MAX_NEW_SWIMMER_SHARE = 0.40
    MAX_NEW_TEAM_SHARE = 0.25

    module_function

    def confirmed?(row)
      row.is_a?(Hash) && row['confirmed'] == true
    end

    def below_bar?(row)
      (row['match_percentage'] || 0.0).to_f < MATCH_BAR
    end

    # == Teams

    def confidently_new_team?(team)
      team['team_id'].blank? && Array(team['fuzzy_matches']).empty? && team['similar_affiliated'] != true
    end

    def team_needs_review?(team)
      return false if confirmed?(team)
      return true if DataFix::Phase3Harmonizer.phase3_conflict_hint?(team)
      return false if confidently_new_team?(team)
      return true if team['team_id'].blank? # (a candidate exists: fuzzy matches or a similar affiliated team)

      below_bar?(team)
    end

    # Review filter of the teams page: review rows + unconfirmed new teams.
    def team_in_review_filter?(team)
      return false if confirmed?(team)

      team_needs_review?(team) || team['team_id'].blank?
    end

    # True when more than MAX_NEW_TEAM_SHARE of the teams have no id.
    def too_many_new_teams?(teams)
      teams = Array(teams)
      return false if teams.empty?

      teams.count { |team| team['team_id'].blank? }.fdiv(teams.size) > MAX_NEW_TEAM_SHARE
    end

    # == Swimmers

    def confidently_new_swimmer?(swimmer)
      swimmer['swimmer_id'].blank? && Array(swimmer['fuzzy_matches']).empty? &&
        swimmer['gender_type_code'].present? && swimmer['year_of_birth'].to_i.positive? &&
        swimmer['category_type_id'].present?
    end

    # True for a new (nil-id) swimmer that can't be created as it is (missing gender, year or category).
    def incomplete_new_swimmer?(swimmer)
      swimmer['swimmer_id'].blank? &&
        (swimmer['gender_type_code'].blank? || swimmer['year_of_birth'].to_i <= 0 || swimmer['category_type_id'].blank?)
    end

    def swimmer_needs_review?(swimmer)
      return false if confirmed?(swimmer)
      return true if swimmer['gender_guessed'] == true || swimmer['auto_assigned_from_secondary_match'] == true ||
                     swimmer['has_badge_duplicates'] == true
      return !confidently_new_swimmer?(swimmer) if swimmer['swimmer_id'].blank?

      below_bar?(swimmer)
    end

    # Review filter of the swimmers page: review rows + unconfirmed new swimmers.
    def swimmer_in_review_filter?(swimmer)
      return false if confirmed?(swimmer)

      swimmer_needs_review?(swimmer) || swimmer['swimmer_id'].blank?
    end

    # True when more than MAX_NEW_SWIMMER_SHARE of the swimmers have no id.
    def too_many_new_swimmers?(swimmers)
      swimmers = Array(swimmers)
      return false if swimmers.empty?

      swimmers.count { |swimmer| swimmer['swimmer_id'].blank? }.fdiv(swimmers.size) > MAX_NEW_SWIMMER_SHARE
    end

    # == Phase 1

    # True when the meeting was matched by its FIN event id (Phase1Solver 'meeting_match').
    def meeting_matched_by_fin?(phase1_data)
      phase1_data.to_h.dig('meeting_match', 'source') == 'fin_event_id'
    end

    # == The ready rule

    # True when every verdict is clean and the preflight has no errors.
    def ready?(verdicts, preflight_errors: [])
      Array(verdicts).all?(&:clean?) && Array(preflight_errors).empty?
    end

    # Entry shown by the commit summary for a confidently-new team / swimmer.
    def new_team_entry(team)
      { 'key' => team['key'], 'name' => team['editable_name'].presence || team['name'] || team['key'] }
    end

    def new_swimmer_entry(swimmer)
      { 'key' => swimmer['key'], 'name' => swimmer['complete_name'].presence || [swimmer['last_name'], swimmer['first_name']].compact.join(' '),
        'year_of_birth' => swimmer['year_of_birth'], 'gender_type_code' => swimmer['gender_type_code'] }
    end
  end
end
