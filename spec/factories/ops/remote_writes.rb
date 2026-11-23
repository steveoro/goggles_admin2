# frozen_string_literal: true

FactoryBot.define do
  factory :ops_remote_write, class: 'Ops::RemoteWrite' do
    http_method { 'put' }
    sequence(:endpoint) { |n| "user/#{n}" }
    base_url { 'http://localhost:8081' }
    status_code { 200 }
    unreachable { false }
    payload_keys { %w[description] }
    source { 'api_users#update' }
  end
end
