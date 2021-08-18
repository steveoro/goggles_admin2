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
  get 'users/index'
  get 'import_queues/index'

  # Needed by datagrid:
  resources :stats do
    get 'stats'
  end
  delete 'stats/:id', to: 'stats#delete', as: 'stats_delete'
end
