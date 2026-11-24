# frozen_string_literal: true

module DataFix
  # TeamsController: Phase 2 (teams) review & edit actions, plus team verification.
  class TeamsController < BaseController
    def review_teams
      # Built when missing, when the 'teams' list is missing (older generator or corrupted file: an empty list is
      # valid for meeting-only sources) or on rescan: DataFix::Pipeline#build_needed?
      phase_path = pipeline.phase_path(2)
      return unless ensure_phase_file!(phase: 2, review_path: method(:review_teams_path))

      refresh_matches_if_db_changed!(2)
      @retry_needed = pipeline.settle!(2)
      pfm = PhaseFileManager.new(phase_path)
      @phase2_meta = pfm.meta
      @phase2_data = pfm.data

      teams_state_cookie_scope = data_fix_review_cookie_scope(prefix: 'teams', file_path: @file_path)

      teams = Array(@phase2_data['teams'])
      apply_review_filters(
        collection: teams,
        prefix: 'teams',
        cookie_scope: teams_state_cookie_scope,
        default_per_page: 50,
        text_fields: %w[name editable_name name_variations key],
        default_filter_state: 'review'
      ) do |list, state|
        case state
        # Filter teams needing review (DataFix::ReviewRules): unconfirmed teams with a candidate, a match under the
        # 89% bar or a phase3-derived conflict hint, plus the unconfirmed new teams. A saved (confirmed) team leaves it.
        when 'review'
          list.select { |t| DataFix::ReviewRules.team_in_review_filter?(t) }
        # Filter teams where the edited name differs from the original import key
        when 'diff_key'
          list.select do |t|
            editable = t['editable_name'].to_s.strip.downcase
            name = t['name'].to_s.strip.downcase
            key = t['key'].to_s.strip.downcase
            (editable.present? && editable != key) || (name.present? && name != key)
          end
        else
          list
        end
      end

      # (phase 12) next/previous issue across the pages of the filtered list
      @issue_nav = DataFix::IssueNav.for_list(@filtered_collection.map { |team| DataFix::IssueMarkers.team(team).present? },
                                              page: @page, per_page: @per_page) do |page, position|
        review_teams_path(file_path: @file_path, phase2_v2: 1, filter_state: @filter_state, q: @q.presence,
                          teams_per_page: @per_page, teams_page: page, anchor: "team-card-#{position}")
      end

      # Broadcast ready status to clear progress modal
      broadcast_progress('Review teams: ready', @total_count, @total_count)
    end

    # AJAX endpoint: cross-validate a Phase 2 team match using swimmer badges from Phase 3.
    # Returns JSON with confidence score and swimmer badge details.
    def verify_team
      file_path = params[:file_path]
      team_key = params[:team_key]
      candidate_team_id = params[:candidate_team_id].to_i

      unless file_path.present? && team_key.present? && candidate_team_id.positive?
        render json: { error: 'Missing required params' }, status: :unprocessable_content
        return
      end

      source_path = source_resolver.resolve_working_source_path(file_path)
      phase3_path = source_resolver.default_phase_path_for(source_path, 3)

      unless File.exist?(phase3_path)
        render json: { error: 'Phase 3 file not found. Please run Phase 3 (Swimmers) first.' }, status: :not_found
        return
      end

      phase3_pfm = PhaseFileManager.new(phase3_path)
      phase3_data = phase3_pfm.data || {}
      season_id = phase3_data['season_id'] || source_resolver.detect_season_from_pathname(source_path)&.id

      checker = Import::Verification::TeamSwimmerChecker.new(phase3_data: phase3_data, season_id: season_id)
      result = checker.check(team_key: team_key, candidate_team_id: candidate_team_id)

      render json: result
    end

    # Update a single Phase 2 team entry by key
    def update_phase2_team
      file_path = @file_path
      source_path = @source_path
      team_key = params[:team_key]
      if team_key.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      phase_path = source_resolver.default_phase_path_for(source_path, 2)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      teams = Array(data['teams'])

      # Find team by key (not index, since filtering changes indices)
      team_index = teams.find_index { |t| t['key'] == team_key }
      if team_index.nil?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
      end

      t = teams[team_index] || {}
      old_team_id = t['team_id'] # Capture before update for cascade detection
      # Saving the card confirms the row: it leaves the review filter (DataFix::ReviewRules)
      t['confirmed'] = true

      # Handle direct params from form (team[field])
      # Note: AutoComplete component adds extra fields (team, city, area) which we permit but ignore
      team_params = params[:team]
      permitted = ActionController::Parameters.new
      if team_params.is_a?(ActionController::Parameters)
        permitted = team_params.permit(:team_id, :editable_name, :name, :name_variations, :city_id,
                                       :team, :city, :area)

        # Update team_id (from AutoComplete)
        if permitted.key?(:team_id)
          team_num = permitted[:team_id].to_i
          t['team_id'] = team_num.positive? ? team_num : nil
        end

        # Update text fields
        t['editable_name'] = sanitize_str(permitted[:editable_name]) if permitted.key?(:editable_name)
        t['name'] = sanitize_str(permitted[:name]) if permitted.key?(:name)
        t['name_variations'] = sanitize_str(permitted[:name_variations]) if permitted.key?(:name_variations)
      end

      city_widget_params = params["team_#{team_index}_city"]
      city_widget_value = (city_widget_params.permit(:city_id)[:city_id] if city_widget_params.is_a?(ActionController::Parameters))

      # Update city_id (from hidden binding field or city widget fallback).
      # Explicit blank from the city widget means user requested unmatch.
      if city_widget_value.is_a?(String) && city_widget_value.strip.empty?
        t['city_id'] = nil
      elsif permitted.key?(:city_id)
        city_num = permitted[:city_id].to_i
        t['city_id'] = city_num.positive? ? city_num : nil
      elsif city_widget_value.present?
        city_num = city_widget_value.to_i
        t['city_id'] = city_num.positive? ? city_num : nil
      end

      teams[team_index] = t
      # Keep team_affiliations in sync with team edits (team_id/manual selections)
      affiliations = Array(data['team_affiliations'])
      season_id = data['season_id'] || params[:season_id]
      aff_index = affiliations.find_index { |a| a['team_key'] == team_key }
      if aff_index
        affiliations[aff_index]['team_id'] = t['team_id']
        affiliations[aff_index]['season_id'] ||= season_id
      else
        affiliations << {
          'team_key' => team_key,
          'season_id' => season_id,
          'team_id' => t['team_id'],
          'team_affiliation_id' => nil
        }
        aff_index = affiliations.size - 1
      end

      aff_row = affiliations[aff_index]
      resolved_affiliation_id = nil
      if t['team_id'].to_i.positive? && season_id.to_i.positive?
        resolved_affiliation_id = GogglesDb::TeamAffiliation.find_by(team_id: t['team_id'], season_id: season_id)&.id
      end
      # Always overwrite with deterministic resolution (or nil) to avoid stale bindings.
      aff_row['team_affiliation_id'] = resolved_affiliation_id

      data['team_affiliations'] = affiliations
      data['teams'] = teams

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      # Cascade team binding updates to Phase 3 badges and Phase 5 DataImport rows
      phase3_path = source_resolver.default_phase_path_for(source_path, 3)
      new_team_id = t['team_id']
      cascade_count = 0
      if File.exist?(phase3_path)
        cascade_count = DataFix::TeamCascade.cascade_team_to_phase3(phase3_path, team_key, new_team_id, season_id)
        phase3_badges = Array(PhaseFileManager.new(phase3_path).data&.dig('badges'))
        cascade_count += DataFix::TeamCascade.cascade_team_to_data_import_rows(
          team_key,
          new_team_id,
          season_id,
          phase_file_path: source_path,
          phase2_affiliations: affiliations,
          phase3_badges: phase3_badges
        )
        restamp_after_cascade!(phases: [3, 5], keys: ['p2'])
      elsif old_team_id != new_team_id
        cascade_count = DataFix::TeamCascade.cascade_team_to_data_import_rows(
          team_key,
          new_team_id,
          season_id,
          phase_file_path: source_path,
          phase2_affiliations: affiliations
        )
        restamp_after_cascade!(phases: [5], keys: ['p2'])
      end
      # Phase 2 saved: refresh the Phase 3 conflict hints (runner write, re-stamped; it may add hints to OTHER teams)
      hints_before = conflict_hints_by_key(teams)
      pipeline.reload!.harmonize!
      cascade_info = I18n.t('data_fix.flash.team_cascaded', count: cascade_count) if cascade_count.positive?

      respond_to do |format|
        # (phase 12) saved in place: the card, the team ranking, the stepper and the toasts are replaced
        format.turbo_stream { render_team_saved(team_key:, cascade_info:, hints_before:) }
        format.html do
          flash[:info] = cascade_info if cascade_info
          # Preserve pagination and filter params
          redirect_params = review_redirect_params(v2_flag: :phase2_v2, keep: %i[teams_page teams_per_page q filter_state])
          redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
        end
      end
    end

    # Create a new blank team entry in Phase 2 and redirect back to v2 view
    def add_team
      source_path = @source_path
      phase_path = source_resolver.default_phase_path_for(source_path, 2)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      teams = Array(data['teams'])

      # Build minimal blank team payload
      new_index = teams.size
      teams << {
        'key' => "New Team #{new_index + 1}",
        'name' => "New Team #{new_index + 1}",
        'editable_name' => "New Team #{new_index + 1}",
        'name_variations' => nil,
        'team_id' => nil,
        'city_id' => nil
      }

      data['teams'] = teams

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                               keep: %i[teams_page teams_per_page q filter_state])

      redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end

    # Delete a team entry from Phase 2 and clear downstream phase data
    def delete_team
      file_path = @file_path
      source_path = @source_path
      team_key = params[:team_key]

      if team_key.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      phase_path = source_resolver.default_phase_path_for(source_path, 2)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      teams = Array(data['teams'])

      # Find and remove team by key (not index, since filtering changes indices)
      team_index = teams.find_index { |t| t['key'] == team_key }
      if team_index.nil?
        flash[:warning] = I18n.t('data_import.data_fix.team_not_found', key: team_key)
        redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
      end

      # Remove the team at the found index
      teams.delete_at(team_index)
      data['teams'] = teams

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                               keep: %i[teams_page teams_per_page q filter_state])

      redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end

    private

    # Phase 3 conflict hints of each team ({ key => [[candidate id, reason], ...] }).
    def conflict_hints_by_key(teams)
      Array(teams).to_h do |team|
        hints = Array(team['fuzzy_matches']).select { |match| match['from_phase3_conflict_hint'] == true }
        [team['key'], hints.map { |match| [match['id'], match['phase3_conflict_reason']] }]
      end
    end

    # Turbo-stream answer of a team saved in place (update_phase2_team.turbo_stream.haml): the phase file is the one
    # the HTML path writes; the edit marker is written first, so that the replaced stepper shows it. Only the saved
    # card is replaced (the positions of the other cards on the page are not known here): when the harmonizer gave
    # other teams new Phase 3 hints, a warning names them and asks for a reload.
    def render_team_saved(team_key:, cascade_info:, hints_before:)
      mark_phase_edited_now!
      set_api_url
      @phase2_data = PhaseFileManager.new(pipeline.phase_path(2)).data || {}
      teams = Array(@phase2_data['teams'])
      @team_key = team_key
      @team_hash = teams.find { |team| team['key'] == team_key } || {}
      @card_index = params[:card_index].presence&.to_i || teams.index(@team_hash).to_i
      flash.now[:notice] = I18n.t('data_import.messages.updated')
      flash.now[:info] = cascade_info if cascade_info
      changed = conflict_hints_by_key(teams).reject { |key, hints| key == team_key || hints == hints_before.fetch(key, []) }.keys
      flash.now[:warning] = I18n.t('data_fix.flash.team_hints_changed', count: changed.size, teams: changed.first(5).join(', ')) if changed.any?
      render 'data_fix/update_phase2_team'
    end
  end
end
