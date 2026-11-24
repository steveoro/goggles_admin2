# frozen_string_literal: true

FactoryBot.define do
  factory :ops_event, class: 'Ops::Event' do
    occurred_at { Time.current }
    sequence(:kind) { |n| "spec.event_#{n}" }
    level { 'info' }
    actor { 'system' }
    data { {} }
  end
end
