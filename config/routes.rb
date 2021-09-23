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

  # Datagrid-actioned routes: (use prefix to avoid clashing w/ Engine resource routes)
  resources :api_badges, only: %i[index create update]
  delete 'api_badges', to: 'api_badges#destroy', as: 'api_badges_destroy'

  resources :api_import_queues, only: %i[index create update]
  delete 'api_import_queues', to: 'api_import_queues#destroy', as: 'api_import_queues_destroy'

  resources :api_meeting_reservations, only: %i[index create update]
  delete 'api_meeting_reservations', to: 'api_meeting_reservations#destroy', as: 'api_meeting_reservations_destroy'

  resources :api_meetings, only: %i[index create update]
  delete 'api_meetings', to: 'api_meetings#destroy', as: 'api_meetings_destroy'

  resources :api_team_managers, only: %i[index create update]
  delete 'api_team_managers', to: 'api_team_managers#destroy', as: 'api_team_managers_destroy'

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
