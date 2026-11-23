# frozen_string_literal: true

# rubocop:disable Rails/LexicallyScopedActionFilter -- filters here apply to actions defined on the per-phase subclasses

require 'date'
require 'pathname'
require 'json'

module DataFix
  # BaseController: shared plumbing for the per-phase DataFix controllers.
  # Holds everything that crosses phases: the canonical source-path guard,
  # review filter/cookie helpers, the shared SourceResolver instance and the
  # helper_method delegators used by the review views.
  class BaseController < ApplicationController
    # Render the shared app/views/data_fix/* templates regardless of the
    # per-phase controller name.
    def self.local_prefixes
      ['data_fix']
    end
    private_class_method :local_prefixes

    # @api_url is only needed by actions that render review views.
    before_action :set_api_url, only: %i[review_sessions review_teams review_swimmers review_events review_results]

    # Resolves @file_path → @source_path for every action taking a file_path param.
    # (Actions with different params or custom error handling manage their own checks.)
    before_action :set_source_path, except: %i[purge coded_name teams_for_swimmer
                                               verify_result confirm_result_duplicate verify_team
                                               update_individual_result_overwrite_candidate
                                               update_individual_result_merge_candidate
                                               bulk_update_individual_result_overwrite]

    TURBO_FILTER_MIN_QUERY_LENGTH = 3

    # Mutating actions => the phase they edit (DataFix::Pipeline#mark_edited!, after a successful response).
    EDIT_ACTIONS = {
      'update_phase1_meeting' => 1, 'update_phase1_session' => 1, 'add_session' => 1, 'delete_session' => 1,
      'rescan_phase1_sessions' => 1,
      'update_phase2_team' => 2, 'add_team' => 2, 'delete_team' => 2,
      'update_phase3_swimmer' => 3, 'add_swimmer' => 3, 'delete_swimmer' => 3, 'merge_phase3_swimmers' => 3,
      'update_phase4_event' => 4, 'add_event' => 4, 'delete_event' => 4,
      'toggle_individual_result_overwrite' => 5, 'update_individual_result_overwrite_candidate' => 5,
      'update_individual_result_merge_candidate' => 5, 'bulk_update_individual_result_overwrite' => 5,
      'confirm_result_duplicate' => 5
    }.freeze

    after_action :mark_phase_edited!, only: EDIT_ACTIONS.keys.map(&:to_sym)

    # Expose issue detection helpers to views
    helper_method :swimmer_has_missing_data?, :relay_result_has_issues?, :phase3_conflict_hint?, :pipeline_summary

    private

    # Shared resolver for this request (keeps the parsed_source_json memo hot)
    def source_resolver
      @source_resolver ||= DataFix::SourceResolver.new
    end

    # Resolves @file_path → @source_path (canonical LT4 working copy) for every
    # action taking a file_path param; redirects to the file list when missing.
    def set_source_path
      @file_path = params[:file_path]
      if @file_path.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      @source_path = source_resolver.resolve_working_source_path(@file_path)
      @file_path = @source_path
    end

    # Params hash for redirects back to a phase-review page: the canonical file
    # path + the v2 flag + the preserved pagination/filter params listed in +keep+.
    def review_redirect_params(v2_flag:, keep: [])
      keep.each_with_object({ file_path: @file_path, v2_flag => 1 }) do |key, hash|
        hash[key] = params[key] if params[key].present?
      end
    end

    # The DataFix::Pipeline of the current source (interactive: Cable progress, operator actor).
    def pipeline
      @pipeline ||= DataFix::Pipeline.for(@source_path, progress: progress_sink, actor: :operator,
                                                        user_id: current_user&.id, source_resolver:)
    end

    # Per-phase verdicts + stage of the current source, for the stepper (nil when no source is resolved).
    def pipeline_summary
      return nil if @source_path.blank?

      @pipeline_summary ||= pipeline.summary
    rescue StandardError => e
      Rails.logger.warn("[DataFix] pipeline summary failed for #{@source_path}: #{e.class}: #{e.message}")
      nil
    end

    # Guard for phase-review actions: builds the phase file through DataFix::Pipeline#build_phase! when missing,
    # incomplete (#build_needed?), when a rescan is requested (the only forced rebuild of an edited phase, asked
    # with a confirmation by the stepper) or, for Step 5 only, when phase 5 is stale and holds no edits; then
    # redirects back to the same review page minus :rescan. Returns false when a redirect was issued — the caller
    # must return immediately in that case.
    def ensure_phase_file!(phase:, review_path:)
      auto_rebuild = params[:rescan].blank? && phase == 5 && auto_rebuild_phase5?
      return true unless params[:rescan].present? || pipeline.build_needed?(phase) || auto_rebuild

      rebuild_phase_and_redirect!(phase:, review_path:,
                                  notice: auto_rebuild ? I18n.t('data_fix.pipeline.phase5_auto_rebuilt') : nil) do
        pipeline.build_phase!(phase, force: true, strict_upstream: false)
        pipeline.last_build_result[:notice]
      end
      false
    rescue DataFix::Pipeline::LeaseBusyError
      redirect_to(data_fix_sessions_path, flash: { warning: I18n.t('data_fix.pipeline.lease_busy') })
      false
    end

    # Steps 2 and 3: when the local DB was committed to since the phase was built (data_fix.db_generation) and the
    # phase holds new entities, opening the step re-resolves only those nil-id rows (DataFix::Pipeline#refresh_new_entities!:
    # ids set by the operator and confirmed rows are left alone; the file is re-stamped, so this is no edit).
    def refresh_matches_if_db_changed!(phase)
      return unless pipeline.db_stale?(phase)

      counts = pipeline.refresh_new_entities!
      pipeline.reload!
      flash.now[:info] = I18n.t('data_fix.pipeline.matches_refreshed', teams: counts[:teams], swimmers: counts[:swimmers])
    rescue DataFix::Pipeline::LeaseBusyError
      nil
    end

    # Step 5 rebuilds by itself only a stale phase 5 without operator edits, fixes or overwrite selections.
    def auto_rebuild_phase5?
      return false unless pipeline.phase_exists?(5) && pipeline.stale?(5).any?
      return false if pipeline.edited?(5) || pipeline.result_free?

      overwrite = pipeline.phase_meta(5)['individual_result_overwrite']
      !(overwrite.is_a?(Hash) && Array(overwrite.dig('snapshot', 'candidates')).any? { |candidate| candidate['selected'] == true })
    end

    # Runs +rebuild+, then redirects to +review_path+ (a callable returning the
    # review URL for given query params) minus the :rescan flag so that
    # subsequent navigation doesn't trigger another rebuild. The block may
    # return a String to override the default "phase rebuilt" notice.
    def rebuild_phase_and_redirect!(phase:, review_path:, notice: nil)
      built_notice = yield
      notice ||= built_notice if built_notice.is_a?(String)
      query = request.query_parameters.except(:rescan).merge(file_path: @file_path)
      redirect_to(review_path.call(query),
                  notice: notice.presence || I18n.t('data_import.messages.phase_rebuilt', phase: phase))
    end

    # Shared filter + pagination block for the phase 2/3 review pages.
    # Sets @filter_state, @q, @page, @per_page, @total_count, @total_pages,
    # @row_range, @items; persists them into the per-file review-state cookie.
    # The block receives (collection, @filter_state) and must return the
    # phase-specific filtered collection (the 'review'/'diff_key' predicates
    # differ per phase); without a block only the text-query filter applies.
    def apply_review_filters(collection:, prefix:, cookie_scope:, default_per_page:, text_fields:)
      @filter_state = data_fix_review_param_or_cookie(param_key: :filter_state, cookie_scope: cookie_scope).to_s
      @filter_state = 'none' unless %w[none review diff_key].include?(@filter_state)
      @q = data_fix_review_param_or_cookie(param_key: :q, cookie_scope: cookie_scope).to_s.strip

      # Filter by search query (ignore if shorter than min chars)
      if @q.present? && @q.length >= TURBO_FILTER_MIN_QUERY_LENGTH
        qd = @q.downcase
        collection = collection.select do |item|
          text_fields.filter_map { |field| item[field] }.any? { |v| v.to_s.downcase.include?(qd) }
        end
      end

      collection = yield(collection, @filter_state) if block_given?

      page_key = :"#{prefix}_page"
      per_page_key = :"#{prefix}_per_page"

      # Reset page to 1 when the filter form is submitted (filter_state or
      # per_page changed without an explicit page param)
      if (params.key?(:filter_state) || params.key?(per_page_key)) && !params.key?(page_key)
        @page = 1
      else
        @page = data_fix_review_param_or_cookie(param_key: page_key, cookie_scope: cookie_scope).to_i
        @page = 1 if @page < 1
      end
      @per_page = data_fix_review_param_or_cookie(param_key: per_page_key, cookie_scope: cookie_scope).to_i
      @per_page = default_per_page if @per_page <= 0
      @total_count = collection.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      @page = @total_pages if @page > @total_pages && @total_pages.positive?
      @row_range = "#{(@page * @per_page) - @per_page + 1}-#{@page * @per_page}"
      @items = Kaminari.paginate_array(collection, total_count: @total_count).page(@page).per(@per_page)

      persist_data_fix_review_state(
        cookie_scope: cookie_scope,
        state: {
          filter_state: @filter_state,
          q: @q,
          page_key => @page,
          per_page_key => @per_page
        }
      )
    end

    # Cookies are scoped by season directory + file basename so that same-named
    # sources staged under different seasons keep separate filter/page state.
    def data_fix_review_cookie_scope(prefix:, file_path:)
      season_dir = File.basename(File.dirname(file_path.to_s))
      basename = File.basename(file_path.to_s, File.extname(file_path.to_s))
      # no length cap: truncating would re-merge scopes for same-season files
      # sharing a >60-char basename prefix (cookie names just need sanitizing)
      sanitized = "#{season_dir}-#{basename}".gsub(/[^a-zA-Z0-9_-]/, '_')
      "data_fix_#{prefix}_#{sanitized}"
    end

    def data_fix_review_param_or_cookie(param_key:, cookie_scope:)
      return params[param_key] if params.key?(param_key)

      cookies["#{cookie_scope}_#{param_key}"]
    end

    def persist_data_fix_review_state(cookie_scope:, state:)
      expires_at = 12.hours.from_now
      state.each do |key, value|
        cookies["#{cookie_scope}_#{key}"] = {
          value: value.to_s,
          expires: expires_at,
          same_site: :lax
        }
      end
    end

    # (after_action) Records the operator edit of the phase changed by a successful mutating action
    # (a redirect without warning/error/alert flash, or a successful JSON answer).
    def mark_phase_edited!
      phase = EDIT_ACTIONS[action_name]
      source_path = @edited_source_path.presence || @source_path
      return if phase.nil? || source_path.blank? || !edit_succeeded?

      DataFix::Pipeline.for(source_path, progress: Import::Progress::Null.new, user_id: current_user&.id)
                       .mark_edited!(phase, action: action_name)
    rescue StandardError => e
      Rails.logger.warn("[DataFix] edit marker not written for #{action_name}: #{e.class}: #{e.message}")
    end

    def edit_succeeded?
      return %i[warning error alert].none? { |key| flash[key].present? } if response.redirect?

      return false unless response.successful?

      body = response.parsed_body
      !(body.is_a?(Hash) && body['success'] == false)
    rescue StandardError
      response.successful?
    end

    # Re-stamps the downstream phases kept in step by a cascade (DataFix::TeamCascade / SwimmerCascade), so that
    # they are not reported stale for the upstream change they already absorbed.
    def restamp_after_cascade!(phases:, keys:)
      fresh = DataFix::Pipeline.for(@source_path, progress: Import::Progress::Null.new, source_resolver:)
      Array(phases).each { |phase| fresh.restamp!(phase, keys:) if fresh.phase_exists?(phase) }
    rescue StandardError => e
      Rails.logger.warn("[DataFix] restamp after cascade failed: #{e.class}: #{e.message}")
    end

    # Setter for @api_url
    def set_api_url
      @api_url = "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
      flash.now[:error] = I18n.t('lookup.errors.api_url_not_set') if @api_url.blank?
    end

    # Minimal string sanitizer for form inputs
    def sanitize_str(val)
      return nil if val.nil?
      return val.strip if val.is_a?(String)

      val
    end

    # Delegates to DataFix::Phase3Harmonizer (exposed to views via helper_method)
    def phase3_conflict_hint?(team_row)
      DataFix::Phase3Harmonizer.phase3_conflict_hint?(team_row)
    end

    # Delegates to DataFix::IssueDetector (exposed to views via helper_method)
    def swimmer_has_missing_data?(swimmer_key, swimmers_by_key: {})
      DataFix::IssueDetector.swimmer_has_missing_data?(swimmer_key, swimmers_by_key: swimmers_by_key)
    end
    # NOTE: build_phase3_category_issues_summary was removed.
    # Category issues are now detected and shown via RelayEnrichmentDetector
    # which includes missing_category in its issue detection.

    # Delegates to DataFix::IssueDetector (exposed to views via helper_method)
    def relay_result_has_issues?(relay_result, **kwargs)
      DataFix::IssueDetector.relay_result_has_issues?(relay_result, **kwargs)
    end

    # Progress sink of the interactive requests (ActionCable 'ImportStatusChannel', see Import::Progress):
    # passed to the pipeline, the solvers and the committer as their +progress:+ keyword.
    def progress_sink
      @progress_sink ||= Import::Progress::Cable.new
    end

    # Broadcast progress updates via ActionCable for real-time UI feedback
    # Used during long-running operations (team/swimmer/result processing)
    def broadcast_progress(message, current, total)
      progress_sink.call(message, current, total)
    end
    #-- -------------------------------------------------------------------------
    #++
  end
end

# rubocop:enable Rails/LexicallyScopedActionFilter
