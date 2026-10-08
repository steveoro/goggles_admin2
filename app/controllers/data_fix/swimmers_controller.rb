# frozen_string_literal: true

module DataFix
  # SwimmersController: Phase 3 (swimmers) review, edit and merge actions.
  class SwimmersController < BaseController
    def review_swimmers
      redirect_to(review_swimmers_legacy_path(request.query_parameters)) && return if params[:phase3_v2].blank?

      source_path = @source_path
      season = source_resolver.detect_season_from_pathname(source_path)
      categories_cache = PdfResults::CategoriesCache.cached_for(season)
      lt_format = source_resolver.detect_layout_type(source_path)
      phase_path = source_resolver.default_phase_path_for(source_path, 3)
      return unless ensure_phase_file!(phase_path: phase_path, phase: 3,
                                       review_path: method(:review_swimmers_path)) do
        Import::Solvers::SwimmerSolver.new(season:, categories_cache:).build!(
          source_path: source_path,
          lt_format: lt_format,
          phase1_path: source_resolver.default_phase_path_for(source_path, 1),
          phase2_path: source_resolver.default_phase_path_for(source_path, 2)
        )
      end

      @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
      pfm = PhaseFileManager.new(phase_path)
      @phase3_meta = pfm.meta
      @phase3_data = pfm.data

      # Safety: rebuild Phase 3 file if swimmers dictionary is missing (older generator or corrupted file)
      if @phase3_data['swimmers'].nil?
        phase1_path = source_resolver.default_phase_path_for(source_path, 1)
        phase2_path = source_resolver.default_phase_path_for(source_path, 2)
        Import::Solvers::SwimmerSolver.new(season:, categories_cache:).build!(
          source_path: source_path,
          lt_format: lt_format,
          phase1_path: phase1_path,
          phase2_path: phase2_path
        )
        redirect_to(review_swimmers_path(request.query_parameters.merge(file_path: @file_path)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 3)) && return
      end
      @source_path = source_path
      base_dir = File.dirname(source_path)

      # Extract season and meeting date for category computation
      season = source_resolver.detect_season_from_pathname(source_path)
      phase1_path = source_resolver.default_phase_path_for(source_path, 1)
      meeting_date = (PhaseFileManager.new(phase1_path).data&.dig('meeting', 'header_date') if File.exist?(phase1_path))

      detector = Phase3::RelayEnrichmentDetector.new(
        source_path: source_path,
        phase3_swimmers: @phase3_data.fetch('swimmers', []),
        season: season,
        meeting_date: meeting_date,
        categories_cache:
      )
      @show_new_relay_swimmers = params[:show_new_relay_swimmers].present?
      @relay_enrichment_summary = DataFix::RelayEnrichmentFilter.filter_relay_enrichment_summary(detector.detect, @show_new_relay_swimmers, @phase3_data)
      @auxiliary_phase3_files = Dir.glob(File.join(base_dir, '*-phase3*.json'))
                                   .reject { |path| path == phase_path }
                                   .sort
      stored_auxiliary = Array(@phase3_meta['auxiliary_phase3_paths']).filter_map do |stored_path|
        next if stored_path.blank?

        begin
          Pathname.new(File.expand_path(stored_path, base_dir)).to_s
        rescue StandardError
          nil
        end
      end
      @selected_auxiliary_phase3_files = stored_auxiliary & @auxiliary_phase3_files

      swimmers_state_cookie_scope = data_fix_review_cookie_scope(prefix: 'swimmers', file_path: @file_path)

      consistency_stats = DataFix::Phase3Harmonizer.harmonize_phase2_phase3_team_links(source_path: source_path, season_id: season.id)
      if consistency_stats.values.sum.positive?
        summary = []
        summary << "#{consistency_stats[:phase2_conflicts_detected]} conflict(s) detected" if consistency_stats[:phase2_conflicts_detected].positive?
        summary << "#{consistency_stats[:phase2_missing_links_detected]} missing link(s) detected" if consistency_stats[:phase2_missing_links_detected].positive?
        summary << "#{consistency_stats[:phase2_conflict_hints_added]} hint candidate(s) added" if consistency_stats[:phase2_conflict_hints_added].positive?
        flash.now[:notice] = { body: "Cross-phase review: #{summary.join(', ')}.", sticky: true }
      end

      swimmers = Array(@phase3_data['swimmers'])
      duplicate_summary = DataFix::Phase3Harmonizer.annotate_swimmer_badge_duplicates!(swimmers)
      if duplicate_summary[:swimmers_with_duplicates].positive?
        flash.now[:warning] = {
          body: "#{duplicate_summary[:swimmers_with_duplicates]} swimmer(s) show duplicate badges in season(s): #{duplicate_summary[:duplicate_seasons].join(', ')}",
          sticky: true
        }
      end

      apply_review_filters(
        collection: swimmers,
        prefix: 'swimmers',
        cookie_scope: swimmers_state_cookie_scope,
        default_per_page: 100,
        text_fields: %w[last_name first_name complete_name key]
      ) do |list, state|
        case state
        # Filter swimmers needing review: unmatched (no swimmer_id) OR match < 89% (yellow/red matches)
        # OR similar name found on same team (cross-ref warning)
        # OR duplicate badges found in same season with different team_id (manual merge red flag)
        # OR auto-assigned from secondary match due to team priority
        # This shows ALL swimmers that need manual verification at a glance
        when 'review'
          list.select do |s|
            # WARNING: adding the 'similar_on_team' check will yield false positives and basically make the filtering useless
            s['swimmer_id'].nil? || (s['match_percentage'] || 0.0) < 89.0 || s['has_badge_duplicates'] == true || s['auto_assigned_from_secondary_match'] == true
          end
        # Filter swimmers where the current name differs from the original import key
        when 'diff_key'
          list.reject do |s|
            complete_name = s['complete_name'].to_s.strip.downcase
            # Extract LAST|FIRST from key by stripping gender prefix, YOB, and team token
            key_name = s['key'].to_s.sub(/^[MF]\|/i, '').split('|').first(2).join(' ').strip.downcase
            complete_name == key_name
          end
        else
          list
        end
      end

      # Broadcast ready status to clear progress modal
      broadcast_progress('Review swimmers: ready', @total_count, @total_count)
    end

    # Update a single Phase 3 swimmer entry by key
    def update_phase3_swimmer
      file_path = @file_path
      source_path = @source_path
      swimmer_key = params[:swimmer_key]

      if swimmer_key.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      phase_path = source_resolver.default_phase_path_for(source_path, 3)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      swimmers = Array(data['swimmers'])

      # Find swimmer by key (not index, since filtering changes indices)
      swimmer_index = swimmers.find_index { |s| s['key'] == swimmer_key }
      if swimmer_index.nil?
        flash[:warning] = I18n.t('data_import.data_fix.swimmer_not_found', key: swimmer_key)
        redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
      end

      # Get swimmer params - handle nested params from AutoComplete
      swimmer_params = params[:swimmer] || {}

      # Update the swimmer at the found index
      swimmer = swimmers[swimmer_index]
      old_swimmer_id = swimmer['swimmer_id']
      swimmer['complete_name'] = swimmer_params[:complete_name]&.strip if swimmer_params.key?(:complete_name)
      swimmer['first_name'] = swimmer_params[:first_name]&.strip if swimmer_params.key?(:first_name)
      swimmer['last_name'] = swimmer_params[:last_name]&.strip if swimmer_params.key?(:last_name)
      swimmer['year_of_birth'] = swimmer_params[:year_of_birth].to_i if swimmer_params.key?(:year_of_birth)
      swimmer['gender_type_code'] = swimmer_params[:gender_type_code]&.strip if swimmer_params.key?(:gender_type_code)
      if swimmer_params.key?(:id)
        swimmer_id_num = swimmer_params[:id].to_i
        swimmer['swimmer_id'] = swimmer_id_num.positive? ? swimmer_id_num : nil
      end

      data['swimmers'] = swimmers

      # Keep badges in sync with swimmer edits (ID and existing badge lookup)
      badges = Array(data['badges'])
      season_id = data['season_id'] || params[:season_id]
      canonical_swimmer_key = swimmer['key']
      badges.each do |badge|
        bkey = badge['swimmer_key']
        next unless DataFix::SwimmerKey.swimmer_key_match?(bkey, swimmer_key, canonical_swimmer_key)

        badge['swimmer_id'] = swimmer['swimmer_id']
        badge['swimmer_key'] = canonical_swimmer_key if canonical_swimmer_key.present?
        resolved_badge_id = nil
        if swimmer['swimmer_id'].to_i.positive? && badge['team_id'].to_i.positive? && season_id.to_i.positive?
          resolved_badge_id = GogglesDb::Badge.find_by(
            season_id: season_id,
            swimmer_id: swimmer['swimmer_id'],
            team_id: badge['team_id']
          )&.id
        end

        # Always overwrite with deterministic resolution (or nil) to avoid stale bindings.
        badge['badge_id'] = resolved_badge_id
      end
      data['badges'] = badges

      # Clear downstream phase data (phase4+) when swimmers are modified
      data['meeting_event'] = [] if data.key?('meeting_event')
      data['meeting_program'] = [] if data.key?('meeting_program')
      data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
      data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      cascade_count = DataFix::SwimmerCascade.cascade_swimmer_to_data_import_rows(
        source_path: source_path,
        old_swimmer_key: swimmer_key,
        canonical_swimmer_key: canonical_swimmer_key,
        old_swimmer_id: old_swimmer_id,
        new_swimmer_id: swimmer['swimmer_id'],
        season_id: season_id,
        phase3_badges: badges
      )
      flash[:info] = "Swimmer updated. Cascaded swimmer links to #{cascade_count} downstream record(s)." if cascade_count.positive?

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                               keep: %i[swimmers_page swimmers_per_page q filter_state])

      redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end

    # Add a new blank swimmer to Phase 3
    def add_swimmer
      source_path = @source_path
      phase_path = source_resolver.default_phase_path_for(source_path, 3)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      swimmers = Array(data['swimmers'])

      # Create a new blank swimmer entry
      new_index = swimmers.size + 1
      new_swimmer = {
        'key' => "NEW|SWIMMER|#{new_index}",
        'last_name' => 'NEW',
        'first_name' => 'SWIMMER',
        'year_of_birth' => Time.zone.now.year - 30,
        'gender_type_code' => 'M',
        'complete_name' => "NEW SWIMMER #{new_index}",
        'swimmer_id' => nil,
        'fuzzy_matches' => []
      }

      swimmers << new_swimmer
      data['swimmers'] = swimmers

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                               keep: %i[swimmers_page swimmers_per_page q filter_state])

      redirect_to review_swimmers_path(redirect_params), notice: 'Swimmer added' # rubocop:disable Rails/I18nLocaleTexts
    end

    # Merge auxiliary Phase 3 files to enrich relay swimmers
    def merge_phase3_swimmers
      file_path = @file_path
      source_path = @source_path
      selected_paths = Array(params[:auxiliary_paths]).compact_blank
      base_dir = File.dirname(source_path)
      phase_path = source_resolver.default_phase_path_for(source_path, 3)

      unless File.exist?(phase_path)
        flash[:warning] = I18n.t('data_import.relay_enrichment.errors.missing_phase_file')
        redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
      end

      if selected_paths.empty?
        flash[:warning] = I18n.t('data_import.relay_enrichment.errors.no_selection')
        redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
      end

      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      meta = pfm.meta || {}

      warnings = []
      resolved_aux_paths = selected_paths.filter_map do |raw|
        abs_path = Pathname.new(File.expand_path(raw, base_dir)).to_s
        if File.exist?(abs_path)
          abs_path
        else
          warnings << I18n.t('data_import.relay_enrichment.errors.missing_file', file: File.basename(raw))
          nil
        end
      rescue StandardError
        warnings << I18n.t('data_import.relay_enrichment.errors.invalid_path', path: raw)
        nil
      end

      if resolved_aux_paths.empty?
        flash[:warning] = warnings.presence || I18n.t('data_import.relay_enrichment.errors.no_valid_files')
        redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
      end

      merger = Phase3::RelayMergeService.new(data.deep_dup)

      # First, enrich from own badges (same file) - badges often have gender from individual results
      merger.self_enrich!

      resolved_aux_paths.each do |aux_path|
        payload = JSON.parse(File.read(aux_path))
        aux_data = payload.is_a?(Hash) ? payload['data'] || payload : {}
        merger.merge_from(aux_data)
      rescue JSON::ParserError
        warnings << I18n.t('data_import.relay_enrichment.errors.unreadable_file', file: File.basename(aux_path))
      end

      merged_data = merger.result
      %w[meeting_event meeting_program meeting_individual_result meeting_relay_result].each do |key|
        merged_data[key] = [] if merged_data.key?(key)
      end

      relative_aux_paths = resolved_aux_paths.map do |abs|
        Pathname.new(abs).relative_path_from(Pathname.new(base_dir)).to_s
      rescue StandardError
        abs
      end

      meta['auxiliary_phase3_paths'] = relative_aux_paths

      pfm.write!(data: merged_data, meta: meta)

      stats = merger.stats
      flash[:notice] = I18n.t('data_import.relay_enrichment.merge_success',
                              swimmers_updated: stats[:swimmers_updated],
                              badges_added: stats[:badges_added])

      # Add warning for ambiguous partial matches
      ambiguous = stats[:partial_matches_ambiguous] || []
      if ambiguous.any?
        ambiguous_names = ambiguous.map { |a| "#{a[:name]} (#{a[:issue]})" }.join(', ')
        warnings << I18n.t('data_import.relay_enrichment.ambiguous_matches', names: ambiguous_names)
      end

      flash[:warning] = warnings.join(' ') if warnings.present?

      redirect_to review_swimmers_path(file_path:, phase3_v2: 1)
    end

    # Delete a swimmer entry from Phase 3 and clear downstream phase data
    def delete_swimmer
      file_path = @file_path
      source_path = @source_path
      swimmer_key = params[:swimmer_key]

      if swimmer_key.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      phase_path = source_resolver.default_phase_path_for(source_path, 3)
      pfm = PhaseFileManager.new(phase_path)
      data = pfm.data || {}
      swimmers = Array(data['swimmers'])

      # Find and remove swimmer by key (not index, since filtering changes indices)
      swimmer_index = swimmers.find_index { |s| s['key'] == swimmer_key }
      if swimmer_index.nil?
        flash[:warning] = I18n.t('data_import.data_fix.swimmer_not_found', key: swimmer_key)
        redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
      end

      # Remove the swimmer at the found index
      swimmers.delete_at(swimmer_index)
      data['swimmers'] = swimmers

      # Clear downstream phase data (phase4+) when swimmers are modified
      data['meeting_event'] = [] if data.key?('meeting_event')
      data['meeting_program'] = [] if data.key?('meeting_program')
      data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
      data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                               keep: %i[swimmers_page swimmers_per_page q filter_state])

      redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end
  end
end
