# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::ActionPaths
  #
  # Where the next action of a Season board row leads (shared by SeasonBoard::RowComponent and the
  # pages summarising the board, e.g. the dashboard inbox), from its NextAction alone: works with a
  # SeasonBoard::Row and with a stored SeasonBoard::Snapshot::Row.
  #
  # Three kinds of action (see StateResolver::ACTIONS):
  # - link actions (LINK_ACTIONS): a GET to the Data-Fix review step or to the Outbox focused on the row's
  #   script (#link_path);
  # - POST actions (POST_ACTIONS): a POST of the FIN event id only to a board action, which looks the
  #   URLs up server side (#post_path);
  # - :link: needs a calendar choice, made on the board row itself (#board_row_path).
  #
  # == Usage
  #   target = SeasonBoard::ActionPaths.target_for(row.next_action)
  #   target.http_method # => :get or :post
  #   target.path        # => '/data_fix/review_swimmers?file_path=...&phase3_v2=1'
  #   target.params      # => {} or { fin_event_id: '150091' } (form fields of a POST)
  #
  module ActionPaths
    # Actions run through a POST of the FIN event ID: kind => route helper
    POST_ACTIONS = { crawl: :season_board_crawl_path, check_results: :season_board_crawl_path,
                     extract_manifest: :season_board_extract_path, prepare: :season_board_prepare_path }.freeze

    # Actions leading to another page with a GET (:commit opens the commit summary: the commit itself is a click there)
    LINK_ACTIONS = %i[review_results review_structure review_header resume_review push commit].freeze

    # Data-Fix review step for each phase number: [route helper, params key]
    PHASE_STEPS = {
      1 => %i[review_sessions_path phase_v2], 2 => %i[review_teams_path phase2_v2],
      3 => %i[review_swimmers_path phase3_v2], 4 => %i[review_events_path phase4_v2],
      5 => %i[review_results_path phase5_v2]
    }.freeze

    # Target of an action: http_method (:get or :post), path, params (POST form fields, Symbol keys).
    Target = Data.define(:http_method, :path, :params) do
      def post? = http_method == :post
    end

    module_function

    # True when the action kind (Symbol or String) is run with a POST of the FIN event ID.
    def post?(kind)
      POST_ACTIONS.key?(kind&.to_sym)
    end

    # True when the action kind (Symbol or String) leads to another page with a GET.
    def link?(kind)
      LINK_ACTIONS.include?(kind&.to_sym)
    end

    # POST path for a POST action (nil for any other action or a nil +next_action+).
    def post_path(next_action)
      helper = next_action && POST_ACTIONS[next_action.kind&.to_sym]
      helper && url_helpers.public_send(helper)
    end

    # GET path for a link action (nil for any other action or a nil +next_action+).
    def link_path(next_action)
      case next_action&.kind&.to_sym
      when :review_results, :review_structure, :review_header
        url_helpers.review_sessions_path(file_path: next_action.params[:file_path], phase_v2: 1)
      when :resume_review
        review_step_path(next_action.params[:file_path], next_action.params[:phase], filter_state: next_action.params[:filter_state])
      when :push
        outbox_focus_path(next_action.params[:sql_path])
      when :commit
        url_helpers.data_fix_commit_summary_path(file_path: next_action.params[:file_path])
      end
    end

    # Data-Fix review step +phase+ of the file (optional +filter_state+, e.g. 'review': the step opens filtered).
    def review_step_path(file_path, phase, filter_state: nil)
      helper, key = PHASE_STEPS.fetch(phase.to_i, PHASE_STEPS[1])
      url_helpers.public_send(helper, { file_path:, key => 1, filter_state: filter_state.presence }.compact)
    end

    # Season board path scrolled to the row of the FIN event id (e.g. for the :link action, whose
    # calendar choice is made on the row). Optional +state+ filter (shows the row even when hidden
    # by default).
    def board_row_path(fin_event_id, state: nil)
      url_helpers.season_board_path({ state: state.presence&.to_s, anchor: row_dom_id(fin_event_id) }.compact)
    end

    # DOM id of the board row (see SeasonBoard::RowComponent).
    def row_dom_id(fin_event_id)
      "season-board-row-#{fin_event_id}"
    end

    # Returns the Target of the NextAction (nil when +next_action+ is nil or of an unknown kind).
    def target_for(next_action)
      kind = next_action&.kind&.to_sym
      if link?(kind)
        Target.new(http_method: :get, path: link_path(next_action), params: {})
      elsif post?(kind)
        Target.new(http_method: :post, path: post_path(next_action), params: { fin_event_id: next_action.params[:fin_event_id].to_s })
      elsif kind == :link
        Target.new(http_method: :get, path: board_row_path(next_action.params[:fin_event_id]), params: {})
      end
    end

    # Outbox page focused on (scrolled to) the script at +sql_path+ (the bare Outbox page without one).
    def outbox_focus_path(sql_path)
      name = File.basename(sql_path.to_s)
      url_helpers.outbox_path(name.present? ? { focus: name } : {})
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
    private_class_method :url_helpers
  end
end
