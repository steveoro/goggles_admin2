# frozen_string_literal: true

module Shell
  #
  # = Shell::Navigation
  #
  # Single source for the sidebar, the breadcrumbs and (phase 15) the command palette.
  # Each later phase adds or replaces only its own entries in ITEMS.
  #
  # == Items
  # - key: unique Symbol; group: one of GROUPS; icon: Font Awesome 6 solid icon name (e.g. 'fa-gauge');
  # - label_key: i18n key of the label (en + it);
  # - path: lambda evaluated against the app URL helpers (see #path_for);
  # - match: list of 'controller_path', 'controller_path#action' or 'controller_path#action?param=value'
  #   entries; the most specific match wins (see #item_for);
  # - parent: key of the parent item (breadcrumbs); offline_ok: reachable in an API-offline session;
  # - sidebar: false for contextual items reached only from another page (e.g. Data-Fix);
  # - keywords: extra search terms for the command palette.
  #
  class Navigation # rubocop:disable Metrics/ClassLength
    GROUPS = %i[dashboard import data_quality entities reports support system].freeze

    Item = Data.define(:key, :group, :icon, :label_key, :path, :match, :parent, :offline_ok, :sidebar, :keywords) do
      def offline_ok? = offline_ok
      def sidebar? = sidebar
    end

    # A sidebar group: its key and the items shown in it.
    # When +offline+ is true (API-offline session), the items without +offline_ok+ are disabled.
    Group = Data.define(:key, :items, :offline) do
      def label_key = "shell.groups.#{key}"
      def disabled?(item) = offline && !item.offline_ok?
    end

    # Builds an Item (keyword defaults included).
    def self.item(key, group, icon, label_key, path, match:, parent: nil, offline_ok: false, sidebar: true, keywords: []) # rubocop:disable Metrics/ParameterLists
      Item.new(key:, group:, icon:, label_key:, path:, match:, parent:, offline_ok:, sidebar:, keywords:)
    end
    private_class_method :item

    # The six Best results pages (routes '<action>_results', labels 'best_results.<action>.button_label').
    BEST_RESULTS_ACTIONS = %i[best_50m best_50_and_100 best_50_and_100_5y best_in_3y best_in_5y all_time_best].freeze # rubocop:disable Naming/VariableNumber

    ITEMS = [
      item(:dashboard, :dashboard, 'fa-gauge', 'dashboard.title', -> { root_path }, match: %w[dashboard], offline_ok: true),
      item(:activity, :dashboard, 'fa-timeline', 'dashboard.activity.title', -> { activity_path },
           match: %w[dashboard#activity_log], parent: :dashboard, offline_ok: true, sidebar: false, keywords: %w[events log history]),
      # Import
      item(:season_board, :import, 'fa-table-list', 'season_board.nav', -> { season_board_path }, match: %w[season_board]),
      item(:crawler, :import, 'fa-spider', 'data_import.calendar.crawler_status_page_title', -> { pull_index_path },
           match: %w[pull#index]),
      item(:calendar_files, :import, 'fa-calendar', 'data_import.calendar.calendar_files_page_title', -> { pull_calendar_files_path },
           match: %w[pull#calendar_files pull#calendar_meetings]),
      item(:pdfs, :import, 'fa-file-pdf', 'data_import.calendar.pdfs_page_title',
           -> { pull_result_files_path(filter: '*.pdf', parent_folder: 'pdfs') },
           match: %w[pull#result_files?parent_folder=pdfs pdf]),
      item(:result_files, :import, 'fa-file-pen', 'data_import.calendar.result_files_page_title', -> { pull_result_files_path },
           match: %w[pull#result_files]),
      item(:data_fix, :import, 'fa-wand-magic', 'shell.nav.data_fix', -> { pull_result_files_path },
           match: %w[data_fix data_fix/sessions data_fix/teams data_fix/swimmers data_fix/events data_fix/results data_fix/commits
                     data_fix/commit_reports],
           parent: :result_files, sidebar: false),
      item(:data_fix_sessions, :import, 'fa-clock-rotate-left', 'data_fix_sessions.nav', -> { data_fix_sessions_path },
           match: %w[data_fix/sessions_list]),
      # (07: the SQL Outbox replaces the Push page; '/push/index' only redirects here)
      item(:outbox, :import, 'fa-paper-plane', 'outbox.nav', -> { outbox_path }, match: %w[outbox push],
                                                                                 offline_ok: true, keywords: %w[push sql scripts upload send]),
      # Data quality
      item(:health, :data_quality, 'fa-heart-pulse', 'health.nav', -> { health_path },
           match: %w[health health/seasons health/sections health/findings health/runs],
           keywords: %w[health report duplicates badges cancelled closed seasons]),
      # (08: local DB vs production fingerprints; reads only the ops DB)
      item(:db_sync, :data_quality, 'fa-code-compare', 'db_sync.nav', -> { db_sync_path },
           match: %w[db_sync], offline_ok: true, keywords: %w[drift fingerprint sync production restore]),
      # (11: the maintenance operations, the fixes of the health findings; 13 extends it)
      item(:operations, :data_quality, 'fa-screwdriver-wrench', 'maintenance.nav', -> { operations_path },
           match: %w[operations maintenance/runs], keywords: %w[fix merge dedupe cancelled backfill ranks maintenance]),
      # (14: guided local DB restore, a contextual child of DB sync; its progress page uses the restore layout)
      item(:db_restore, :data_quality, 'fa-database', 'db_restore.nav', -> { db_sync_path },
           match: %w[db_restore], parent: :db_sync, offline_ok: true, sidebar: false, keywords: %w[restore dump rebuild]),
      # Entities
      item(:meetings, :entities, 'fa-flag-checkered', 'dashboard.meetings.title', -> { api_meetings_path }, match: %w[api_meetings]),
      item(:calendars, :entities, 'fa-calendar-days', 'dashboard.calendars.title', -> { api_calendars_path }, match: %w[api_calendars]),
      item(:reservations, :entities, 'fa-clipboard-list', 'dashboard.meeting_reservations.title', -> { api_meeting_reservations_path },
           match: %w[api_meeting_reservations]),
      item(:swimmers, :entities, 'fa-person-swimming', 'dashboard.swimmers.title', -> { api_swimmers_path }, match: %w[api_swimmers]),
      item(:teams, :entities, 'fa-people-group', 'dashboard.teams.title', -> { api_teams_path }, match: %w[api_teams]),
      item(:badges, :entities, 'fa-id-badge', 'dashboard.badges.title', -> { api_badges_path }, match: %w[api_badges]),
      item(:team_affiliations, :entities, 'fa-link', 'dashboard.team_affiliations.title', -> { api_team_affiliations_path },
           match: %w[api_team_affiliations]),
      item(:team_managers, :entities, 'fa-user-tie', 'dashboard.team_managers.title', -> { api_team_managers_path },
           match: %w[api_team_managers]),
      item(:seasons, :entities, 'fa-calendar-check', 'dashboard.seasons.title', -> { api_seasons_path }, match: %w[api_seasons]),
      item(:categories, :entities, 'fa-layer-group', 'dashboard.categories.title', -> { api_categories_path }, match: %w[api_categories]),
      item(:standard_timings, :entities, 'fa-stopwatch', 'dashboard.standard_timings.title', -> { api_standard_timings_path },
           match: %w[api_standard_timings]),
      item(:swimming_pools, :entities, 'fa-water', 'dashboard.swimming_pools.title', -> { api_swimming_pools_path },
           match: %w[api_swimming_pools]),
      # Reports: the six best_results pages + GogglesCup
      *BEST_RESULTS_ACTIONS.map do |act|
        item(act, :reports, 'fa-ranking-star', "best_results.#{act}.button_label",
             -> { public_send(:"#{act}_results_path") }, match: ["best_results##{act}"])
      end,
      item(:goggles_cup, :reports, 'fa-trophy', 'goggles_cup.button_label', -> { goggles_cup_preview_path }, match: %w[goggles_cup]),
      # Support
      item(:users, :support, 'fa-users', 'dashboard.users.title', -> { api_users_path }, match: %w[api_users]),
      item(:issues, :support, 'fa-bug', 'dashboard.issues.title', -> { api_issues_path }, match: %w[api_issues]),
      item(:import_queues, :support, 'fa-list-check', 'dashboard.import_queues.title', -> { api_import_queues_path },
           match: %w[api_import_queues]),
      item(:api_stats, :support, 'fa-chart-line', 'dashboard.stats.title', -> { stats_path }, match: %w[stats]),
      item(:trainings, :support, 'fa-camera', 'api_trainings.title', -> { api_trainings_path }, match: %w[api_trainings]),
      item(:user_workshops, :support, 'fa-chalkboard-user', 'dashboard.user_workshops.title', -> { api_user_workshops_path },
           match: %w[api_user_workshops]),
      # System
      item(:settings, :system, 'fa-gear', 'dashboard.settings.title', -> { settings_path }, match: %w[settings], offline_ok: true),
      item(:remote_writes, :system, 'fa-tower-broadcast', 'remote_writes.nav', -> { remote_writes_path },
           match: %w[remote_writes], offline_ok: true, keywords: %w[drift api log])
    ].freeze

    ITEMS_BY_KEY = ITEMS.index_by(&:key).freeze

    class << self
      # Returns the non-empty sidebar groups (in GROUPS order), each with its +sidebar+ items.
      # With <tt>offline: true</tt> each Group reports the items unavailable in an API-offline session as disabled.
      def groups(offline: false)
        GROUPS.filter_map do |group_key|
          items = ITEMS.select { |item| item.group == group_key && item.sidebar? }
          Group.new(key: group_key, items:, offline:) if items.any?
        end
      end

      # Returns the Item for the given key, or nil.
      def find(key)
        ITEMS_BY_KEY[key&.to_sym]
      end

      # Returns the Item matching the request (most specific match wins), or nil.
      #
      # == Params:
      # - controller_path: e.g. 'data_fix/teams'; action_name: e.g. 'review_teams';
      # - params: request params (ActionController::Parameters or Hash), used by the '?param=value' entries.
      def item_for(controller_path, action_name, params = {})
        query = normalize_params(params)
        best = nil
        best_score = 0
        ITEMS.each do |item|
          score = item.match.map { |entry| match_score(entry, controller_path.to_s, action_name.to_s, query) }.max
          next unless score.positive? && score > best_score

          best = item
          best_score = score
        end
        best
      end

      # Returns the breadcrumbs for the request as an Array of [label, path] pairs (path nil when not a link):
      # group › ancestors › item, plus the action name as the last crumb for a contextual child page
      # (e.g. api_meetings#no_mirs). Empty when the request maps to no item.
      def breadcrumbs_for(controller_path, action_name, params = {})
        item = item_for(controller_path, action_name, params)
        return [] unless item

        crumbs = [[I18n.t("shell.groups.#{item.group}"), nil]]
        lineage(item).each { |node| crumbs << [I18n.t(node.label_key), path_for(node)] }
        action_crumb = action_crumb_for(item, controller_path.to_s, action_name.to_s)
        crumbs << action_crumb if action_crumb
        crumbs
      end

      # Command palette entries (phase 15 stub): one Hash per sidebar item.
      def palette_entries
        ITEMS.select(&:sidebar?).map do |item|
          { key: item.key, group: item.group, icon: item.icon, label: I18n.t(item.label_key), path: path_for(item),
            keywords: item.keywords }
        end
      end

      # Returns the path of the item, evaluating its lambda against the app URL helpers.
      def path_for(item)
        Rails.application.routes.url_helpers.instance_exec(&item.path)
      end

      private

      # Item and its ancestors, root first.
      def lineage(item)
        chain = [item]
        seen = [item.key]
        while (parent = find(chain.first.parent)) && seen.exclude?(parent.key)
          chain.unshift(parent)
          seen << parent.key
        end
        chain
      end

      # Last crumb for a page that is not the item's own landing page but is served by the same controller
      # (e.g. api_meetings#no_mirs under Meetings); nil otherwise.
      def action_crumb_for(item, controller_path, action_name)
        landing = Rails.application.routes.recognize_path(path_for(item).split('?').first)
        return if landing[:controller] != controller_path || landing[:action] == action_name || action_name == 'index'

        [I18n.t("shell.actions.#{action_name}", default: action_name.humanize), nil]
      rescue ActionController::RoutingError
        nil
      end

      # 0 = no match; 1 = controller; 2 = controller#action; 3 = controller#action?param=value.
      def match_score(entry, controller_path, action_name, query)
        target, condition = entry.split('?', 2)
        ctrl, action = target.split('#', 2)
        return 0 unless ctrl == controller_path
        return 1 if action.nil?
        return 0 unless action == action_name
        return 2 if condition.nil?

        key, value = condition.split('=', 2)
        query[key].to_s == value.to_s ? 3 : 0
      end

      def normalize_params(params)
        hash = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
        hash.to_h.stringify_keys
      end
    end
  end
end
