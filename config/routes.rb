# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
Rails.application.routes.draw do
  devise_for :users, class_name: 'GogglesDb::User',
                     controllers: {
                       sessions: 'users/sessions'
                     }
  root to: 'home#index'

  # Mounting and usage of the Engine:
  mount GogglesDb::Engine => '/'

  get 'home/index'

  get 'pull/index'
  get 'pull/calendar_files'
  get 'pull/result_files'
  put 'pull/result_files', to: 'pull#result_files', as: 'update_result_files'

  post 'pull/run_calendar_crawler', to: 'pull#run_calendar_crawler', as: 'run_calendar_crawler'
  get 'pull/edit_name'
  get 'pull/edit_file'
  put 'pull/file_rename'
  put 'pull/file_edit'
  delete 'pull/file_delete'
  post 'pull/process_calendar_file', to: 'pull#process_calendar_file', as: 'process_calendar_file'

  post 'data_fix/prepare_result_file', to: 'data_fix#prepare_result_file', as: 'prepare_result_file'
  get 'push/index'

  # Datagrid-actioned routes: (use prefix to avoid clashing w/ Engine resource routes)
  resources :api_badges, only: %i[index create update]
  delete 'api_badges', to: 'api_badges#destroy', as: 'api_badges_destroy'

  resources :api_categories, only: %i[index create update]
  delete 'api_categories', to: 'api_categories#destroy', as: 'api_categories_destroy'

  resources :api_import_queues, only: %i[index create update]
  delete 'api_import_queues', to: 'api_import_queues#destroy', as: 'api_import_queues_destroy'

  resources :api_meeting_reservations, only: %i[index create update]
  get 'api_meeting_reservations/expand', to: 'api_meeting_reservations#expand', as: 'api_meeting_reservations_expand'
  delete 'api_meeting_reservations', to: 'api_meeting_reservations#destroy', as: 'api_meeting_reservations_destroy'

  resources :api_meetings, only: %i[index update]
  post 'api_meetings/clone', to: 'api_meetings#clone', as: 'api_meetings_clone'

  resources :api_seasons, only: %i[index create update]

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
end
# rubocop:enable Metrics/BlockLength
