# frozen_string_literal: true

module DataFix
  # SwimmersController: Phase 3 (swimmers) review, edit and merge actions.
  class SwimmersController < BaseController
    def review_swimmers
      source_path = @source_path
      # Built when missing, when the 'swimmers' list is missing (older generator or corrupted file) or on rescan:
      # DataFix::Pipeline#build_needed?
      phase_path = pipeline.phase_path(3)
      return unless ensure_phase_file!(phase: 3, review_path: method(:review_swimmers_path))

      season = pipeline.season
      categories_cache = pipeline.categories_cache
      refresh_matches_if_db_changed!(3)
      @retry_needed = pipeline.settle!(3)
      pfm = PhaseFileManager.new(phase_path)
      @phase3_meta = pfm.meta
      @phase3_data = pfm.data
      base_dir = File.dirname(source_path)

      # Meeting date for category computation (phase 1 header_date, else the source date)
      meeting_date = pipeline.meeting_date

      detector = Phase3::RelayEnrichmentDetector.new(
        source_path: source_path,
        phase3_swimmers: @phase3_data.fetch('swimmers', []),
        season: season,
        meeting_date: meeting_date,
        categories_cache:
      )
      @show_new_relay_swimmers = params[:show_new_relay_swimmers].present?
      detected = detector.detect
      @relay_enrichment_summary = DataFix::RelayEnrichmentFilter.filter_relay_enrichment_summary(detected, @show_new_relay_swimmers, @phase3_data)
      # (same count as the Phase 3 verdict: new-only legs hidden; reused by the stepper)
      verdict_summary = @relay_enrichment_summary
      verdict_summary = DataFix::RelayEnrichmentFilter.filter_relay_enrichment_summary(detected, false, @phase3_data) if @show_new_relay_swimmers
      pipeline.relay_enrichment_count = verdict_summary.size
      @auxiliary_phase3_files = Dir.glob(File.join(base_dir, '*-phase3*.json'))
                                   .reject { |path| path == phase_path || path.match?(/\.orig(-\d+)?\.json\z/) }
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

      # Idempotent: writes phase 2 (re-stamped) only when a new conflict hint appears (normally done at build time)
      consistency_stats = pipeline.harmonize!
      if consistency_stats.values.sum.positive?
        summary = {
          'data_fix.flash.conflicts_detected' => consistency_stats[:phase2_conflicts_detected],
          'data_fix.flash.missing_links_detected' => consistency_stats[:phase2_missing_links_detected],
          'data_fix.flash.hints_added' => consistency_stats[:phase2_conflict_hints_added]
        }.select { |_key, count| count.positive? }.map { |key, count| I18n.t(key, count:) }
        flash.now[:notice] = { body: I18n.t('data_fix.flash.cross_phase_review', summary: summary.join(', ')), sticky: true }
      end

      swimmers = Array(@phase3_data['swimmers'])
      duplicate_summary = DataFix::Phase3Harmonizer.annotate_swimmer_badge_duplicates!(swimmers)
      if duplicate_summary[:swimmers_with_duplicates].positive?
        flash.now[:warning] = {
          body: I18n.t('data_fix.flash.duplicate_badges', count: duplicate_summary[:swimmers_with_duplicates],
                                                          seasons: duplicate_summary[:duplicate_seasons].join(', ')),
          sticky: true
        }
      end
      # (swimmer_key => team_key of its badge, shown on the cards)
      @team_key_by_swimmer_key = team_keys_by_swimmer_key(@phase3_data)

      apply_review_filters(
        collection: swimmers,
        prefix: 'swimmers',
        cookie_scope: swimmers_state_cookie_scope,
        default_per_page: 100,
        text_fields: %w[last_name first_name complete_name key],
        default_filter_state: 'review'
      ) do |list, state|
        case state
        # Filter swimmers needing review (DataFix::ReviewRules): unconfirmed matches under the 89% bar, gender-guessed,
        # auto-assigned from a secondary match or with duplicate badges, plus the unconfirmed new swimmers.
        # A saved (confirmed) swimmer leaves it.
        when 'review'
          list.select { |s| DataFix::ReviewRules.swimmer_in_review_filter?(s) }
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

      # (phase 12) next/previous issue across the pages of the filtered list
      @issue_nav = DataFix::IssueNav.for_list(@filtered_collection.map { |swimmer| DataFix::IssueMarkers.swimmer(swimmer).present? },
                                              page: @page, per_page: @per_page) do |page, position|
        review_swimmers_path(file_path: @file_path, phase3_v2: 1, filter_state: @filter_state, q: @q.presence,
                             swimmers_per_page: @per_page, swimmers_page: page, anchor: "swimmer-card-#{position}")
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
        redirect_to(sources_results_path) && return
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
      # Saving the card confirms the row: it leaves the review filter (DataFix::ReviewRules)
      swimmer['confirmed'] = true
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
      cascade_info = I18n.t('data_fix.flash.swimmer_cascaded', count: cascade_count) if cascade_count.positive?
      restamp_after_cascade!(phases: [5], keys: ['p3'])

      respond_to do |format|
        # (phase 12) saved in place: the card, the stepper and the toasts are replaced
        format.turbo_stream { render_swimmer_saved(swimmer_key: canonical_swimmer_key.presence || swimmer_key, cascade_info:) }
        format.html do
          flash[:info] = cascade_info if cascade_info
          # Preserve pagination and filter params
          redirect_params = review_redirect_params(v2_flag: :phase3_v2, keep: %i[swimmers_page swimmers_per_page q filter_state])
          redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
        end
      end
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

      redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_fix.flash.swimmer_added')
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
        redirect_to(sources_results_path) && return
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

      meta = pfm.meta || {}
      pfm.write!(data: data, meta: meta)

      # Preserve pagination and filter params
      redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                               keep: %i[swimmers_page swimmers_per_page q filter_state])

      redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
    end

    private

    # swimmer_key => team_key of its Phase 3 badge.
    def team_keys_by_swimmer_key(phase3_data)
      Array(phase3_data['badges']).each_with_object({}) { |badge, memo| memo[badge['swimmer_key']] = badge['team_key'] if badge['swimmer_key'] }
    end

    # Turbo-stream answer of a swimmer saved in place (update_phase3_swimmer.turbo_stream.haml): the phase file is the
    # one the HTML path writes; the edit marker is written first, so that the replaced stepper shows it.
    def render_swimmer_saved(swimmer_key:, cascade_info:)
      mark_phase_edited_now!
      set_api_url
      phase3_data = PhaseFileManager.new(pipeline.phase_path(3)).data || {}
      swimmers = Array(phase3_data['swimmers'])
      DataFix::Phase3Harmonizer.annotate_swimmer_badge_duplicates!(swimmers)
      @swimmer_key = swimmer_key
      @swimmer_hash = swimmers.find { |swimmer| swimmer['key'] == swimmer_key } || {}
      @swimmer_team_key = team_keys_by_swimmer_key(phase3_data)[swimmer_key]
      @card_index = params[:card_index].presence&.to_i || swimmers.index(@swimmer_hash).to_i
      flash.now[:notice] = I18n.t('data_import.messages.updated')
      flash.now[:info] = cascade_info if cascade_info
      render 'data_fix/update_phase3_swimmer'
    end
  end
end
