# frozen_string_literal: true

Rails.application.routes.draw do
  get 'best50m_results/index'
  devise_for :users, class_name: 'GogglesDb::User',
                     controllers: {
                       sessions: 'users/sessions'
                     }
  root to: 'home#index'

  # Mounting and usage of the Engine:
  mount GogglesDb::Engine => '/'

  get 'home/index'
  get 'home/latest_updates'

  get 'best_results/best_50m', to: 'best_results#best_50m', as: 'best_50m_results'
  get 'best_results/best_50_and_100', to: 'best_results#best_50_and_100', as: 'best_50_and_100_results'
  get 'best_results/best_50_and_100_5y', to: 'best_results#best_50_and_100_5y', as: 'best_50_and_100_5y_results'
  get 'best_results/best_in_3y', to: 'best_results#best_in_3y', as: 'best_in_3y_results'
  get 'best_results/best_in_5y', to: 'best_results#best_in_5y', as: 'best_in_5y_results'
  get 'best_results/all_time_best', to: 'best_results#all_time_best', as: 'all_time_best_results'

  get 'pull/index'
  get 'pull/calendar_files'
  get 'pull/result_files'
  put 'pull/result_files', to: 'pull#result_files', as: 'update_result_files'

  post 'pull/run_crawler_api', to: 'pull#run_crawler_api', as: 'run_crawler_api'
  get 'pull/edit_name'
  get 'pull/edit_file'
  put 'pull/file_rename'
  put 'pull/file_edit'
  delete 'pull/file_delete'
  post 'pull/process_calendar_file', to: 'pull#process_calendar_file', as: 'process_calendar_file'

  get 'pdf/extract_txt', to: 'pdf#extract_txt', as: 'pdf_extract_txt'
  put 'pdf/scan'
  put 'pdf/log_contents'

  get 'data_fix/review_sessions', to: 'data_fix#review_sessions', as: 'review_sessions'
  get 'data_fix/review_teams', to: 'data_fix#review_teams', as: 'review_teams'
  get 'data_fix/review_swimmers', to: 'data_fix#review_swimmers', as: 'review_swimmers'
  get 'data_fix/review_events', to: 'data_fix#review_events', as: 'review_events'
  get 'data_fix/review_results', to: 'data_fix#review_results', as: 'review_results'
  get 'data_fix/results_chunk_v2', to: 'data_fix#results_chunk_v2', as: 'results_chunk_v2'
  patch 'data_fix/update_phase1_meeting', to: 'data_fix#update_phase1_meeting', as: 'update_phase1_meeting'
  patch 'data_fix/update_phase1_session', to: 'data_fix#update_phase1_session', as: 'update_phase1_session'
  patch 'data_fix/update_phase2_team', to: 'data_fix#update_phase2_team', as: 'update_phase2_team'
  patch 'data_fix/update', to: 'data_fix#update', as: 'data_fix_update'
  get 'data_fix/coded_name', to: 'data_fix#coded_name'
  get 'data_fix/teams_for_swimmer/:swimmer_id', to: 'data_fix#teams_for_swimmer', as: 'data_fix_teams_for_swimmer'
  delete 'data_fix/purge', to: 'data_fix#purge', as: 'data_fix_purge'
  get 'data_fix/result_details/:prg_key', to: 'data_fix#result_details', as: 'data_fix_result_details'
  post 'data_fix/add_session', to: 'data_fix#add_session', as: 'data_fix_add_session'
  post 'data_fix/add_event', to: 'data_fix#add_event', as: 'data_fix_add_event'

  # Explicit legacy routes (directly targeting DataFixLegacyController)
  get 'data_fix_legacy/review_sessions', to: 'data_fix_legacy#review_sessions', as: 'review_sessions_legacy'
  get 'data_fix_legacy/review_teams', to: 'data_fix_legacy#review_teams', as: 'review_teams_legacy'
  get 'data_fix_legacy/review_swimmers', to: 'data_fix_legacy#review_swimmers', as: 'review_swimmers_legacy'
  get 'data_fix_legacy/review_events', to: 'data_fix_legacy#review_events', as: 'review_events_legacy'
  get 'data_fix_legacy/review_results', to: 'data_fix_legacy#review_results', as: 'review_results_legacy'
  patch 'data_fix_legacy/update', to: 'data_fix_legacy#update', as: 'data_fix_update_legacy'
  get 'data_fix_legacy/coded_name', to: 'data_fix_legacy#coded_name', as: 'data_fix_coded_name_legacy'
  get 'data_fix_legacy/teams_for_swimmer/:swimmer_id', to: 'data_fix_legacy#teams_for_swimmer', as: 'data_fix_teams_for_swimmer_legacy'
  delete 'data_fix_legacy/purge', to: 'data_fix_legacy#purge', as: 'data_fix_purge_legacy'
  get 'data_fix_legacy/result_details/:prg_key', to: 'data_fix_legacy#result_details', as: 'data_fix_result_details_legacy'
  post 'data_fix_legacy/add_session', to: 'data_fix_legacy#add_session', as: 'data_fix_add_session_legacy'
  post 'data_fix_legacy/add_event', to: 'data_fix_legacy#add_event', as: 'data_fix_add_event_legacy'

  get 'push/index'
  post 'push/prepare'
  post 'push/upload'

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

  resources :api_teams, only: %i[index create update]

  resources :api_user_workshops, only: %i[index create update]
  delete 'api_user_workshops', to: 'api_user_workshops#destroy', as: 'api_user_workshops_destroy'

  resources :api_users, only: %i[index update]
  delete 'api_users', to: 'api_users#destroy', as: 'api_users_destroy'

  resources :settings, only: %i[index update]
  post 'settings/api_config', to: 'settings#api_config', as: 'settings_api_config'
  delete 'settings', to: 'settings#destroy', as: 'settings_destroy'

  resources :stats, only: %i[index update]
  delete 'stats', to: 'stats#destroy', as: 'stats_destroy'
  post 'stats/clear', to: 'stats#clear', as: 'stats_clear'
end
