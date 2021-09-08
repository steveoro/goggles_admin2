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

  # Datagrid-actioned routes:
  resources :badges, only: [:index, :create, :update]
  delete 'badges', to: 'badges#destroy', as: 'badges_destroy'

  resources :import_queues, only: [:index, :create, :update]
  delete 'import_queues', to: 'import_queues#destroy', as: 'import_queues_destroy'

  resources :meeting_reservations, only: [:index, :create, :update]
  delete 'meeting_reservations', to: 'meeting_reservations#destroy', as: 'meeting_reservations_destroy'

  resources :meetings, only: [:index, :create, :update]
  delete 'meetings', to: 'meetings#destroy', as: 'meetings_destroy'

  resources :settings, only: [:index, :create, :update]
  delete 'settings', to: 'settings#destroy', as: 'settings_destroy'

  resources :stats, only: [:index, :update]
  delete 'stats', to: 'stats#destroy', as: 'stats_destroy'

  resources :team_managers, only: [:index, :create, :update]
  delete 'team_managers', to: 'team_managers#destroy', as: 'team_managers_destroy'

  resources :user_workshops, only: [:index, :create, :update]
  delete 'user_workshops', to: 'user_workshops#destroy', as: 'user_workshops_destroy'

  resources :users, only: [:index, :update]
  delete 'users', to: 'users#destroy', as: 'users_destroy'
end
# rubocop:enable Metrics/BlockLength
