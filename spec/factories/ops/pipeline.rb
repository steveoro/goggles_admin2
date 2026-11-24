# frozen_string_literal: true

FactoryBot.define do
  factory :ops_pipeline_source, class: 'Ops::PipelineSource' do
    season_id { 242 }
    sequence(:base) { |n| "2026-11-0#{(n % 9) + 1}-spec-meeting-#{n}" }
    source_path { "/tmp/results.new/#{season_id}/#{base}-lt4.json" }
    stage { 'new' }
  end

  factory :ops_phase_verdict, class: 'Ops::PhaseVerdict' do
    pipeline_source factory: :ops_pipeline_source
    phase { 1 }
    status { 'clean' }
    issues_count { 0 }
    issues { [] }
    counts { {} }
    new_entities { {} }
    checked_at { Time.current }
  end

  factory :ops_commit_report, class: 'Ops::CommitReport' do
    season_id { 242 }
    sequence(:source_base) { |n| "2026-11-0#{(n % 9) + 1}-spec-meeting-#{n}" }
    source_path { "/tmp/results.new/#{season_id}/#{source_base}-lt4.json" }
    status { 'queued' }
    requested_by_user_id { 1 }
    requested_at { Time.current }
  end

  factory :ops_pipeline_run, class: 'Ops::PipelineRun' do
    sequence(:subject_key) { |n| "spec-subject-#{n}" }
    kind { 'build' }
    origin { 'operator' }
    status { 'queued' }
  end
end
