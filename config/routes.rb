# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, class_name: 'GogglesDb::User',
                     controllers: {
                       sessions: 'users/sessions'
                     }
  root to: 'dashboard#index'

  # Mounting and usage of the Engine:
  mount GogglesDb::Engine => '/'

  # Old landing page URL (kept for bookmarks and the locale switch of non-GET pages):
  get 'home/index', to: 'dashboard#index', as: 'home_index'

  # Dashboard zones (lazy Turbo frames, see DashboardController) and actions:
  get 'dashboard/needs_you', to: 'dashboard#needs_you', as: 'dashboard_needs_you'
  get 'dashboard/in_progress', to: 'dashboard#in_progress', as: 'dashboard_in_progress'
  get 'dashboard/season_progress', to: 'dashboard#season_progress', as: 'dashboard_season_progress'
  get 'dashboard/system', to: 'dashboard#system_status', as: 'dashboard_system'
  get 'dashboard/activity', to: 'dashboard#activity_feed', as: 'dashboard_activity'
  get 'dashboard/kpis', to: 'dashboard#kpis', as: 'dashboard_kpis'
  get 'dashboard/health', to: 'dashboard#health', as: 'dashboard_health'
  post 'dashboard/refresh_kpis', to: 'dashboard#refresh_kpis', as: 'dashboard_refresh_kpis'
  post 'dashboard/discard_failed_job', to: 'dashboard#discard_failed_job', as: 'dashboard_discard_failed_job'
  post 'dashboard/retry_failed_job', to: 'dashboard#retry_failed_job', as: 'dashboard_retry_failed_job'
  # Event log (ops DB), paginated:
  get 'activity', to: 'dashboard#activity_log', as: 'activity'

  # Top bar status pills (lazy turbo-frame; see Shell::StatusController):
  get 'shell/status', to: 'shell/status#show', as: 'shell_status'
  # Command palette (Ctrl+K) local search: meetings, teams, swimmers, Data-Fix sessions (see Shell::PaletteController):
  get 'palette/search', to: 'shell/palette#search', as: 'palette_search', defaults: { format: :json }

  get 'best_results/best_50m', to: 'best_results#best_50m', as: 'best_50m_results'
  get 'best_results/best_50_and_100', to: 'best_results#best_50_and_100', as: 'best_50_and_100_results'
  get 'best_results/best_50_and_100_5y', to: 'best_results#best_50_and_100_5y', as: 'best_50_and_100_5y_results'
  get 'best_results/best_in_3y', to: 'best_results#best_in_3y', as: 'best_in_3y_results'
  get 'best_results/best_in_5y', to: 'best_results#best_in_5y', as: 'best_in_5y_results'
  get 'best_results/all_time_best', to: 'best_results#all_time_best', as: 'all_time_best_results'
  get 'best_results/goggles_cup_preview', to: 'goggles_cup#index', as: 'goggles_cup_preview'
  get 'best_results/goggles_cup_preview/smart_selection', to: 'goggles_cup#smart_selection', as: 'smart_selection_goggles_cup_preview'
  match 'best_results/goggles_cup_preview/compute', to: 'goggles_cup#compute', as: 'compute_goggles_cup_preview', via: %i[get post]
  get 'best_results/goggles_cup_preview/base_timings', to: 'goggles_cup#base_timings', as: 'base_timings_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/save', to: 'goggles_cup#save', as: 'save_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/clear_ranking', to: 'goggles_cup#clear_ranking', as: 'clear_ranking_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/apply_local', to: 'goggles_cup#apply_local', as: 'apply_local_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/resync', to: 'goggles_cup#resync', as: 'resync_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/publish', to: 'goggles_cup#publish', as: 'publish_goggles_cup_preview'
  post 'best_results/goggles_cup_preview/unpublish', to: 'goggles_cup#unpublish', as: 'unpublish_goggles_cup_preview'

  # FIN "Riepilogo Eventi" page watcher (see FedernuotoWatchJob):
  post 'federnuoto_watch/check', to: 'federnuoto_watch#check', as: 'federnuoto_watch_check'
  post 'federnuoto_watch/acknowledge', to: 'federnuoto_watch#acknowledge', as: 'federnuoto_watch_acknowledge'
  # (0.10.103: dismisses one FIN calendar notice of the dashboard "Needs you" list, Inbox::Sources::FINNotice)
  post 'federnuoto_watch/dismiss_notice', to: 'federnuoto_watch#dismiss_notice', as: 'federnuoto_watch_dismiss_notice'

  get 'season_board', to: 'season_board#index', as: 'season_board'
  post 'season_board/crawl', to: 'season_board#crawl', as: 'season_board_crawl'
  post 'season_board/extract', to: 'season_board#extract', as: 'season_board_extract'
  post 'season_board/link', to: 'season_board#link', as: 'season_board_link'
  post 'season_board/prepare', to: 'season_board#prepare', as: 'season_board_prepare'
  post 'season_board/hold', to: 'season_board#hold', as: 'season_board_hold'
  post 'season_board/prepare_all', to: 'season_board#prepare_all', as: 'season_board_prepare_all'
  post 'automation/switch', to: 'automation#switch', as: 'automation_switch'

  # Sources area (phase 15): season-aware file lists, manual crawls (SourceCrawlJob), PDF scans (PdfScanJob), manifest
  # extractions (ManifestExtractJob), the "Prepare" of the non-FIN sources and the file manager (Sources::FileGuard).
  get 'sources', to: redirect('/sources/results'), as: 'sources'
  scope 'sources', module: 'sources', as: 'sources', format: false do
    get 'results', to: 'results#index', as: 'results'
    post 'prepare', to: 'results#prepare', as: 'prepare'
    get 'calendars', to: 'calendars#index', as: 'calendars'
    get 'calendars/meetings', to: 'calendars#meetings', as: 'calendar_meetings'
    get 'manifests', to: 'manifests#index', as: 'manifests'
    post 'manifests/extract', to: 'manifests#extract', as: 'manifests_extract'
    get 'pdfs', to: 'pdfs#index', as: 'pdfs'
    get 'pdfs/show', to: 'pdfs#show', as: 'pdf'
    get 'pdfs/scan_result', to: 'pdfs#scan_result', as: 'pdf_scan_result'
    post 'pdfs/scan', to: 'pdfs#scan', as: 'pdf_scan'
    get 'crawler', to: 'crawler#show', as: 'crawler'
    get 'crawler/activity', to: 'crawler#activity', as: 'crawler_activity'
    post 'crawler/start', to: 'crawler#start', as: 'crawler_start'
    post 'crawls', to: 'crawls#create', as: 'crawls'
    get 'files', to: 'files#index', as: 'files'
    delete 'files', to: 'files#destroy', as: 'file_delete'
    get 'files/rename', to: 'files#rename', as: 'file_rename'
    patch 'files/rename', to: 'files#update_name', as: 'file_update_name'
    get 'files/edit', to: 'files#edit', as: 'file_edit'
    patch 'files/edit', to: 'files#update', as: 'file_update'
    # (0.10.104: the clean-up of the redundant files, dry run then the operator's apply)
    get 'cleanup', to: 'cleanups#show', as: 'cleanup'
    post 'cleanup', to: 'cleanups#create'
  end

  # Phase 15: the Pull, PDF and file-list pages became the Sources area. Their GET URLs redirect for one release
  # (bookmarks; the old 'file_path' param becomes 'path'); their POST/PUT/DELETE routes are gone.
  scope format: false do
    legacy_query = lambda do |request, rename = {}|
      query = Rack::Utils.parse_nested_query(request.query_string)
      rename.each { |from, to| query[to] = query.delete(from) if query.key?(from) }
      query.compact_blank.to_query.presence
    end
    legacy_redirect = ->(path, rename = {}) { redirect(status: 301) { |_params, request| [path, legacy_query.call(request, rename)].compact.join('?') } }
    get 'pull/index', to: legacy_redirect.call('/sources/crawler')
    get 'pull/calendar_files', to: legacy_redirect.call('/sources/calendars')
    get 'pull/calendar_meetings', to: legacy_redirect.call('/sources/calendars/meetings', 'file_path' => 'path')
    get 'pull/result_files', to: redirect(status: 301) { |_params, request|
      request.params['parent_folder'] == 'pdfs' ? '/sources/pdfs' : '/sources/results'
    }
    get 'pull/edit_name', to: legacy_redirect.call('/sources/files/rename', 'file_path' => 'path')
    get 'pull/edit_file', to: legacy_redirect.call('/sources/files/edit', 'file_path' => 'path')
    get 'pdf/extract_txt', to: legacy_redirect.call('/sources/pdfs/show', 'file_path' => 'path')
  end

  get 'data_fix/sessions', to: 'data_fix/sessions_list#index', as: 'data_fix_sessions'
  delete 'data_fix/sessions/purge', to: 'data_fix/sessions_list#purge', as: 'data_fix_sessions_purge'
  get 'data_fix/review_sessions', to: 'data_fix/sessions#review_sessions', as: 'review_sessions'
  post 'data_fix/recompute_source_categories', to: 'data_fix/sessions#recompute_source_categories', as: 'recompute_source_categories'
  get 'data_fix/review_teams', to: 'data_fix/teams#review_teams', as: 'review_teams'
  get 'data_fix/review_swimmers', to: 'data_fix/swimmers#review_swimmers', as: 'review_swimmers'
  get 'data_fix/review_events', to: 'data_fix/events#review_events', as: 'review_events'
  get 'data_fix/review_results', to: 'data_fix/results#review_results', as: 'review_results'
  post 'data_fix/toggle_individual_result_overwrite', to: 'data_fix/results#toggle_individual_result_overwrite', as: 'toggle_individual_result_overwrite'
  post 'data_fix/update_individual_result_overwrite_candidate', to: 'data_fix/results#update_individual_result_overwrite_candidate',
                                                                as: 'update_individual_result_overwrite_candidate'
  post 'data_fix/update_individual_result_merge_candidate', to: 'data_fix/results#update_individual_result_merge_candidate',
                                                            as: 'update_individual_result_merge_candidate'
  post 'data_fix/bulk_update_individual_result_overwrite', to: 'data_fix/results#bulk_update_individual_result_overwrite',
                                                           as: 'bulk_update_individual_result_overwrite'
  post 'data_fix/commit_phase6', to: 'data_fix/commits#commit_phase6', as: 'commit_phase6'
  patch 'data_fix/update_phase1_meeting', to: 'data_fix/sessions#update_phase1_meeting', as: 'update_phase1_meeting'
  patch 'data_fix/update_phase1_session', to: 'data_fix/sessions#update_phase1_session', as: 'update_phase1_session'
  post 'data_fix/add_session', to: 'data_fix/sessions#add_session', as: 'data_fix_add_session'
  delete 'data_fix/delete_session', to: 'data_fix/sessions#delete_session', as: 'data_fix_delete_session'
  post 'data_fix/rescan_phase1_sessions', to: 'data_fix/sessions#rescan_phase1_sessions', as: 'rescan_phase1_sessions'
  patch 'data_fix/update_phase2_team', to: 'data_fix/teams#update_phase2_team', as: 'update_phase2_team'
  post 'data_fix/add_team', to: 'data_fix/teams#add_team', as: 'data_fix_add_team'
  delete 'data_fix/delete_team', to: 'data_fix/teams#delete_team', as: 'data_fix_delete_team'
  patch 'data_fix/update_phase3_swimmer', to: 'data_fix/swimmers#update_phase3_swimmer', as: 'update_phase3_swimmer'
  post 'data_fix/add_swimmer', to: 'data_fix/swimmers#add_swimmer', as: 'data_fix_add_swimmer'
  delete 'data_fix/delete_swimmer', to: 'data_fix/swimmers#delete_swimmer', as: 'data_fix_delete_swimmer'
  post 'data_fix/merge_phase3_swimmers', to: 'data_fix/swimmers#merge_phase3_swimmers', as: 'merge_phase3_swimmers'
  patch 'data_fix/update_phase4_event', to: 'data_fix/events#update_phase4_event', as: 'update_phase4_event'
  post 'data_fix/add_event', to: 'data_fix/events#add_event', as: 'data_fix_add_event'
  delete 'data_fix/delete_event', to: 'data_fix/events#delete_event', as: 'data_fix_delete_event'
  get 'data_fix/verify_result', to: 'data_fix/results#verify_result', as: 'data_fix_verify_result'
  patch 'data_fix/confirm_result_duplicate', to: 'data_fix/results#confirm_result_duplicate', as: 'data_fix_confirm_result_duplicate'
  get 'data_fix/verify_team', to: 'data_fix/teams#verify_team', as: 'data_fix_verify_team'
  get 'data_fix/coded_name', to: 'data_fix#coded_name'
  get 'data_fix/teams_for_swimmer/:swimmer_id', to: 'data_fix#teams_for_swimmer', as: 'data_fix_teams_for_swimmer'

  post 'data_fix/retry_archive', to: 'data_fix/commits#retry_archive', as: 'data_fix_retry_archive'
  # (phase 09) pipeline runner: discard edits after a source change, refresh matches, verify all, commit summary + job,
  # persistent commit report (with its polled status frame and its lazy health-runs frame)
  post 'data_fix/discard_phase_edits', to: 'data_fix/sessions#discard_phase_edits', as: 'data_fix_discard_phase_edits'
  # (phase 12) "Rebuild" of the stale banner: one phase, refused for an edited phase without force
  post 'data_fix/rebuild_phase', to: 'data_fix/sessions#rebuild_phase', as: 'data_fix_rebuild_phase'
  post 'data_fix/refresh_matches', to: 'data_fix/commits#refresh_matches', as: 'data_fix_refresh_matches'
  post 'data_fix/verify_all_results', to: 'data_fix/results#verify_all_results', as: 'data_fix_verify_all_results'
  get 'data_fix/commit_summary', to: 'data_fix/commits#summary', as: 'data_fix_commit_summary'
  get 'data_fix/commit_reports/:id', to: 'data_fix/commit_reports#show', as: 'data_fix_commit_report', constraints: { id: /\d+/ }
  get 'data_fix/commit_reports/:id/status', to: 'data_fix/commit_reports#status', as: 'data_fix_commit_report_status',
                                            constraints: { id: /\d+/ }
  get 'data_fix/commit_reports/:id/health', to: 'data_fix/commit_reports#health', as: 'data_fix_commit_report_health',
                                            constraints: { id: /\d+/ }

  # SQL Outbox (phase 07): the old Push page only redirects here.
  get 'push/index', to: 'push#index', as: 'push_index'
  get 'outbox', to: 'outbox#index', as: 'outbox'
  get 'outbox/push/new', to: 'outbox#push_new', as: 'new_outbox_push'
  post 'outbox/push', to: 'outbox#push', as: 'outbox_push'
  post 'outbox/reconcile', to: 'outbox#reconcile', as: 'outbox_reconcile'
  get 'outbox/:id', to: 'outbox#show', as: 'outbox_script', constraints: { id: /\d+/ }
  %w[hold release apply_locally discard resolve].each do |action|
    post "outbox/:id/#{action}", to: "outbox##{action}", as: "#{action}_outbox_script", constraints: { id: /\d+/ }
  end
  # (08: remote outcome actions on a failed script; 'retry' is a Ruby keyword, hence the action name)
  post 'outbox/:id/retry', to: 'outbox#retry_remote', as: 'retry_outbox_script', constraints: { id: /\d+/ }
  post 'outbox/:id/withdraw', to: 'outbox#withdraw', as: 'withdraw_outbox_script', constraints: { id: /\d+/ }
  post 'outbox/:id/abandon', to: 'outbox#abandon', as: 'abandon_outbox_script', constraints: { id: /\d+/ }

  # Datagrid-actioned routes: (use prefix to avoid clashing w/ Engine resource routes)
  resources :api_badges, only: %i[index create update]
  delete 'api_badges', to: 'api_badges#destroy', as: 'api_badges_destroy'

  resources :api_calendars, only: %i[index create update]
  delete 'api_calendars', to: 'api_calendars#destroy', as: 'api_calendars_destroy'

  resources :api_categories, only: %i[index create update]
  delete 'api_categories', to: 'api_categories#destroy', as: 'api_categories_destroy'
  post 'api_categories/clone', to: 'api_categories#clone', as: 'api_categories_clone'

  resources :api_import_queues, only: %i[index create update]
  delete 'api_import_queues', to: 'api_import_queues#destroy', as: 'api_import_queues_destroy'

  resources :api_issues, only: %i[index create update]
  delete 'api_issues', to: 'api_issues#destroy', as: 'api_issues_destroy'
  get 'api_issues/check/:id', to: 'api_issues#check', as: 'api_issue_check'
  post 'api_issues/fix/:id', to: 'api_issues#fix', as: 'api_issue_fix'

  resources :api_meeting_reservations, only: %i[index create update]
  get 'api_meeting_reservations/expand', to: 'api_meeting_reservations#expand', as: 'api_meeting_reservations_expand'
  delete 'api_meeting_reservations', to: 'api_meeting_reservations#destroy', as: 'api_meeting_reservations_destroy'

  resources :api_meetings, only: %i[index update]
  get 'api_meetings/no_mirs', to: 'api_meetings#no_mirs', as: 'api_meetings_no_mirs'
  post 'api_meetings/clone', to: 'api_meetings#clone', as: 'api_meetings_clone'

  resources :api_seasons, only: %i[index create update]

  resources :api_standard_timings, only: %i[index create update]
  delete 'api_standard_timings', to: 'api_standard_timings#destroy', as: 'api_standard_timings_destroy'

  resources :api_swimmers, only: %i[index create update]
  resources :api_swimming_pools, only: %i[index create update]

  resources :api_team_affiliations, only: %i[index create update]
  delete 'api_team_affiliations', to: 'api_team_affiliations#destroy', as: 'api_team_affiliations_destroy'

  resources :api_team_managers, only: %i[index create update]
  delete 'api_team_managers', to: 'api_team_managers#destroy', as: 'api_team_managers_destroy'
  post 'api_team_managers/sql_create', to: 'api_team_managers#sql_create', as: 'api_team_managers_sql_create'

  resources :api_teams, only: %i[index create update]

  resources :api_trainings, only: %i[index new create edit update destroy]

  resources :api_user_workshops, only: %i[index create update]
  delete 'api_user_workshops', to: 'api_user_workshops#destroy', as: 'api_user_workshops_destroy'

  resources :api_users, only: %i[index update]
  delete 'api_users', to: 'api_users#destroy', as: 'api_users_destroy'

  # Localhost-DB JSON lookups for autocomplete widgets (e.g. the SQL-create modal):
  get 'lookup/:domain', to: 'lookup#index', as: 'lookup'
  get 'lookup/:domain/:id', to: 'lookup#show', as: 'lookup_detail'

  resources :settings, only: %i[index update]
  post 'settings/api_config', to: 'settings#api_config', as: 'settings_api_config'
  post 'settings/api_target_label', to: 'settings#api_target_label', as: 'settings_api_target_label'
  delete 'settings', to: 'settings#destroy', as: 'settings_destroy'

  # Log of the API calls that may have changed the remote data (ops DB) + their acknowledgement:
  get 'remote_writes', to: 'remote_writes#index', as: 'remote_writes'
  post 'remote_writes/acknowledge', to: 'remote_writes#acknowledge', as: 'remote_writes_acknowledge'

  # DB sync (phase 08): the local DB vs the API's DB fingerprints (ops DB rows; see DbSyncController, Drift::*):
  get 'db_sync', to: 'db_sync#show', as: 'db_sync'
  post 'db_sync/check', to: 'db_sync#check', as: 'db_sync_check'
  post 'db_sync/acknowledge', to: 'db_sync#acknowledge', as: 'db_sync_acknowledge'

  # Guided local DB restore (phase 14): wizard + progress page (ops DB rows; see DbRestoreController, DbRestore::*):
  scope 'db_restore', controller: 'db_restore', constraints: { id: /\d+/ } do
    get 'new', action: :new, as: 'new_db_restore'
    post '/', action: :create, as: 'db_restores'
    post 'dump_dirs', action: :dump_dirs, as: 'db_restore_dump_dirs'
    get ':id', action: :show, as: 'db_restore'
    get ':id/status', action: :poll, as: 'db_restore_status', defaults: { format: :json }
    get ':id/inspect', action: :inspection, as: 'inspect_db_restore'
    get ':id/confirm', action: :confirmation, as: 'confirmation_db_restore'
    get ':id/result', action: :result, as: 'db_restore_result'
    %w[snapshot confirm cancel resume load_snapshot abandon post_steps].each do |action|
      post ":id/#{action}", action:, as: "#{action}_db_restore"
    end
  end

  # Closed-season data health report (local mirror; ops DB findings & runs, see HealthController & Health::*):
  scope format: false do
    get 'health', to: 'health#index', as: 'health'
    get 'health/matrix', to: 'health#matrix', as: 'health_matrix'
    get 'health/seasons/:season_id', to: 'health/seasons#show', as: 'health_season'
    get 'health/seasons/:season_id/summary', to: 'health/seasons#summary', as: 'health_season_summary'
    get 'health/seasons/:season_id/sections/:check_key', to: 'health/sections#show', as: 'health_section',
                                                         constraints: { check_key: /[a-z_]+(\.[a-z_]+)+/ }
    patch 'health/findings/bulk', to: 'health/findings#bulk', as: 'health_findings_bulk'
    get 'health/findings/:id', to: 'health/findings#show', as: 'health_finding'
    post 'health/runs', to: 'health/runs#create', as: 'health_runs'
    # (phase 11: "Flag cancelled" is the 'meeting.set_cancelled' operation; the old URLs open its form)
    get 'health/cancellations/new', to: redirect(status: 302) { |_params, request| "/operations/meeting.set_cancelled/new?#{request.query_string}".chomp('?') }
    post 'health/cancellations', to: redirect(status: 303) { |_params, request| "/operations/meeting.set_cancelled/new?#{request.query_string}".chomp('?') }
  end

  # Maintenance operations (phase 11): list + history, prefilled form, dry run / apply runs (ops DB; Maintenance::*):
  scope format: false do
    get 'operations', to: 'operations#index', as: 'operations'
    # (the 'operations.enabled' switch: dashboard system column and /operations header)
    post 'operations/switch', to: 'operations#switch', as: 'operations_switch'
    get 'operations/runs/:id', to: 'maintenance/runs#show', as: 'maintenance_run', constraints: { id: /\d+/ }
    get 'operations/runs/:id/status', to: 'maintenance/runs#status', as: 'maintenance_run_status', constraints: { id: /\d+/ }
    post 'operations/runs/:id/apply', to: 'maintenance/runs#apply', as: 'apply_maintenance_run', constraints: { id: /\d+/ }
    get 'operations/:key/new', to: 'operations#new', as: 'new_operation', constraints: { key: /[a-z_]+(\.[a-z_]+)+/ }
    post 'operations/:key/runs', to: 'maintenance/runs#create', as: 'operation_runs', constraints: { key: /[a-z_]+(\.[a-z_]+)+/ }
    # (phase 13: Cancel of a long run; the season-start checklist and its step actions)
    post 'operations/runs/:id/cancel', to: 'maintenance/runs#cancel', as: 'cancel_maintenance_run', constraints: { id: /\d+/ }
    get 'operations/season_start', to: 'maintenance/season_start#index', as: 'season_start_index'
    get 'operations/season_start/:season_id', to: 'maintenance/season_start#show', as: 'season_start', constraints: { season_id: /\d+/ }
    post 'operations/season_start/:season_id/steps/:step_key', to: 'maintenance/season_start#step', as: 'season_start_step',
                                                               constraints: { season_id: /\d+/, step_key: /[a-z_]+/ }
  end

  resources :stats, only: %i[index update]
  delete 'stats', to: 'stats#destroy', as: 'stats_destroy'
  post 'stats/clear', to: 'stats#clear', as: 'stats_clear'
end
