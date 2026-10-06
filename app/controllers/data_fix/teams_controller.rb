# frozen_string_literal: true

module DataFix
  # TeamsController: Phase 2 (teams) review & edit actions, plus team verification.
  class TeamsController < BaseController
    def review_teams
      redirect_to(review_teams_legacy_path(request.query_parameters)) && return if params[:phase2_v2].blank?

      source_path = @source_path
      season = source_resolver.detect_season_from_pathname(source_path)
      lt_format = source_resolver.detect_layout_type(source_path)
      phase_path = source_resolver.default_phase_path_for(source_path, 2)
      return unless ensure_phase_file!(phase_path: phase_path, phase: 2,
                                       review_path: method(:review_teams_path)) do
        Import::Solvers::TeamSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
      end

      @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
      pfm = PhaseFileManager.new(phase_path)
      @phase2_meta = pfm.meta
      @phase2_data = pfm.data

      # Safety: rebuild Phase 2 file if teams dictionary is missing (older generator or corrupted file).
      # NOTE: an empty array is a valid result for meeting-only sources - only a missing key triggers the rebuild.
      if @phase2_data['teams'].nil?
        Import::Solvers::TeamSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
        redirect_to(review_teams_path(request.query_parameters.merge(file_path: @file_path)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 2)) && return
      end

      teams_state_cookie_scope = data_fix_review_cookie_scope(prefix: 'teams', file_path: @file_path)

      teams = Array(@phase2_data['teams'])
      apply_review_filters(
        collection: teams,
        prefix: 'teams',
        cookie_scope: teams_state_cookie_scope,
        default_per_page: 50,
        text_fields: %w[name editable_name name_variations key]
      ) do |list, state|
        case state
        # Filter teams needing review: unmatched (no team_id) OR match < 89% (yellow/red matches)
        # OR similar affiliated team found in season (cross-ref warning)
        # OR phase3-derived conflict hints found for this team
        # This shows ALL teams that need manual verification at a glance
        when 'review'
          list.select do |t|
            # WARNING: adding the 'similar_on_team' check will yield false positives and basically make the filtering useless
            t['team_id'].nil? || (t['match_percentage'] || 0.0) < 89.0 || phase3_conflict_hint?(t) # || t['similar_affiliated'] == true
          end
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
        flash[:info] = "Team updated. Cascaded team_id to #{cascade_count} downstream record(s)." if cascade_count.positive?
      elsif old_team_id != new_team_id
        cascade_count = DataFix::TeamCascade.cascade_team_to_data_import_rows(
          team_key,
          new_team_id,
          season_id,
          phase_file_path: source_path,
          phase2_affiliations: affiliations
        )
        flash[:info] = "Team updated. Cascaded team_id to #{cascade_count} downstream record(s)." if cascade_count.positive?
      end

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                               keep: %i[teams_page teams_per_page q filter_state])

      redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
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
        flash[:warning] = "Team not found: #{team_key}"
        redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
      end

      # Remove the team at the found index
      teams.delete_at(team_index)
      data['teams'] = teams

      # Clear downstream phase data (phase3+) when teams are modified
      # This ensures data consistency across phases
      data['swimmers'] = [] if data.key?('swimmers')
      data['meeting_event'] = [] if data.key?('meeting_event')
      data['meeting_program'] = [] if data.key?('meeting_program')
      data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
      data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                               keep: %i[teams_page teams_per_page q filter_state])

      redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end
  end
end
