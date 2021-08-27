# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, class_name: 'GogglesDb::User',
                     controllers: {
                       sessions: 'users/sessions'
                     }
  root to: 'home#index'

  # Mounting and usage of the Engine:
  mount GogglesDb::Engine => '/'

  get 'home/index'
  get 'meeting_reservations/index'
  get 'badges/index'
  get 'user_workshops/index'
  get 'meetings/index'
  get 'team_managers/index'
  get 'settings/index'
  # get 'users/index'
  # get 'import_queues/index'

  # Datagrid routes:
  resources :stats do
    get 'stats'
  end
  # (1 single modal dialog handles both update & create, using only POST)
  post 'stats/update/:id', to: 'stats#update', as: 'stats_update'
  post 'stats/create', to: 'stats#create', as: 'stats_create'
  delete 'stats', to: 'stats#destroy', as: 'stats_destroy'

  resources :import_queues do
    get 'import_queues'
  end
  post 'import_queues/update/:id', to: 'import_queues#update', as: 'import_queues_update'
  post 'import_queues/create', to: 'import_queues#create', as: 'import_queues_create'
  delete 'import_queues', to: 'import_queues#destroy', as: 'import_queues_destroy'

  resources :users do
    get 'users'
  end
  post 'users/update/:id', to: 'users#update', as: 'users_update'
  post 'users/create', to: 'users#create', as: 'users_create'
  delete 'users', to: 'users#destroy', as: 'users_destroy'

  resources :settings do
    get 'settings'
  end
end
