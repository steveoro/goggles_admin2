# frozen_string_literal: true

FactoryBot.define do
  factory :ops_setting, class: 'Ops::Setting' do
    sequence(:key) { |n| "spec.setting_#{n}" }
    value { { 'enabled' => true } }
  end
end
