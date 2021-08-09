# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, class_name: 'GogglesDb::User'
  root to: 'home#index'

  # Mounting and usage of the Engine:
  mount GogglesDb::Engine => '/'

  get 'home/index'
end
