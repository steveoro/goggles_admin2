# frozen_string_literal: true

FactoryBot.define do
  factory :ops_snapshot, class: 'Ops::Snapshot' do
    sequence(:key) { |n| "spec.snapshot:#{n}" }
    payload { { 'ok' => true } }
    source { 'spec' }
    taken_at { Time.current }
  end
end
