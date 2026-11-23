# frozen_string_literal: true

FactoryBot.define do
  factory :ops_health_run, class: 'Ops::HealthRun' do
    season_id { 242 }
    group_key { 'meetings' }
    trigger { 'manual' }
    status { 'succeeded' }
    check_versions { {} }
    counts { {} }
    db_epoch { 1 }
    started_at { 1.minute.ago }
    finished_at { Time.current }
    duration_ms { 1200 }
  end

  factory :ops_health_finding, class: 'Ops::HealthFinding' do
    season_id { 242 }
    group_key { 'meetings' }
    check_key { 'meetings.no_results.unflagged' }
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("spec-finding-#{n}") }
    severity { 'error' }
    status { 'open' }
    subject_type { 'meeting' }
    sequence(:subject_id) { |n| 19_000 + n }
    title { 'Meeting without results' }
    payload { { 'title_args' => { 'id' => subject_id, 'date' => '2025-03-08', 'description' => 'Trofeo X' } } }
    payload_digest { Ops::HealthFinding.digest_for(payload) }
    first_seen_at { 1.day.ago }
    last_seen_at { Time.current }
  end
end
