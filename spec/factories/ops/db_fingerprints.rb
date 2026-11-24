# frozen_string_literal: true

FactoryBot.define do
  # A stored DB sync check (Ops::DbFingerprint) for the API at 'http://localhost:8081'.
  factory :ops_db_fingerprint, class: 'Ops::DbFingerprint' do
    taken_at { Time.current }
    trigger { 'schedule' }
    mode { 'full' }
    api_base_url { 'http://localhost:8081' }
    target_env { 'development' }
    local { { 'schema_version' => '20261027120100', 'tables' => { 'laps' => { 'count' => 10, 'max_id' => 100 } } } }
    remote { { 'schema_version' => '20261027120100', 'tables' => { 'laps' => { 'count' => 10, 'max_id' => 100 } } } }
    verdict { 'green' }
    reasons { [{ 'code' => 'in_sync', 'table' => nil, 'local' => nil, 'remote' => nil }] }

    trait :red do
      verdict { 'red' }
      reasons { [{ 'code' => 'id_collision', 'table' => 'laps', 'local' => 100, 'remote' => 120 }] }
    end

    trait :amber do
      verdict { 'amber' }
      reasons { [{ 'code' => 'remote_writes', 'table' => nil, 'local' => 2, 'remote' => nil }] }
    end

    trait :unknown do
      verdict { 'unknown' }
      remote { {} }
      reasons { [{ 'code' => 'no_capability', 'table' => nil, 'local' => nil, 'remote' => nil }] }
    end
  end
end
