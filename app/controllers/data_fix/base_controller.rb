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
    before_action :set_api_url, only: %i[review_sessions review_teams review_swimmers review_events
                                         review_results commit_phase6_report]

    # Resolves @file_path → @source_path for every action taking a file_path param.
    # (Actions with different params or custom error handling manage their own checks.)
    before_action :set_source_path, except: %i[commit_phase6_report purge coded_name teams_for_swimmer
                                               verify_result confirm_result_duplicate verify_team
                                               results_chunk_v2
                                               update_individual_result_overwrite_candidate
                                               update_individual_result_merge_candidate
                                               bulk_update_individual_result_overwrite]

    TURBO_FILTER_MIN_QUERY_LENGTH = 3

    # Review actions that redirect to the legacy wizard when their v2 flag is
    # absent. Resolution must be skipped for them: resolve_working_source_path
    # can run category normalization (deleting staged phase files and
    # data_import rows), and the legacy redirect must fire without side effects.
    LEGACY_REDIRECT_FLAGS = {
      'review_sessions' => 'phase_v2', 'review_teams' => 'phase2_v2', 'review_swimmers' => 'phase3_v2',
      'review_events' => 'phase4_v2', 'review_results' => 'phase5_v2'
    }.freeze

    # Expose issue detection helpers to views
    helper_method :swimmer_has_missing_data?, :relay_result_has_issues?, :phase3_conflict_hint?

    private

    # Shared resolver for this request (keeps the parsed_source_json memo hot)
    def source_resolver
      @source_resolver ||= DataFix::SourceResolver.new
    end

    # Resolves @file_path → @source_path (canonical LT4 working copy) for every
    # action taking a file_path param; redirects to the file list when missing.
    def set_source_path
      legacy_flag = LEGACY_REDIRECT_FLAGS[action_name]
      return if legacy_flag && params[legacy_flag].blank?

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

    # Guard for phase-review actions: rebuilds the phase file (via the +rebuild+
    # block) when missing or when a rescan is requested, then redirects back to
    # the same review page minus :rescan. Returns false when a redirect was
    # issued — the caller must return immediately in that case.
    def ensure_phase_file!(phase_path:, phase:, review_path:, &rebuild) # rubocop:disable Naming/PredicateMethod
      return true unless params[:rescan].present? || !File.exist?(phase_path)

      rebuild_phase_and_redirect!(phase: phase, review_path: review_path, &rebuild)
      false
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
      sanitized = "#{season_dir}-#{basename}".gsub(/[^a-zA-Z0-9_-]/, '_').slice(0, 60)
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

    # Broadcast progress updates via ActionCable for real-time UI feedback
    # Used during long-running operations (team/swimmer/result processing)
    def broadcast_progress(message, current, total)
      ActionCable.server.broadcast(
        'ImportStatusChannel',
        { msg: message, progress: current, total: total }
      )
    rescue StandardError => e
      Rails.logger.warn("[DataFixController] Failed to broadcast progress: #{e.message}")
    end
    #-- -------------------------------------------------------------------------
    #++
  end
end

# rubocop:enable Rails/LexicallyScopedActionFilter
