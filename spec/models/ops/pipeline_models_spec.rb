# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Data-Fix pipeline ops models' do # rubocop:disable RSpec/DescribeClass
  describe Ops::PipelineSource do
    it 'derives the DiskIndex base and the season id from a path' do
      expect(described_class.base_for('/x/results.new/262/2026-11-08-foo-lt4.json')).to eq('2026-11-08-foo')
      expect(described_class.base_for('/x/262/2026-11-08-foo-lt4-phase3.json')).to eq('2026-11-08-foo')
      expect(described_class.base_for('/x/262/2026-11-08-foo.json')).to eq('2026-11-08-foo')
      expect(described_class.season_id_for('/x/262/foo.json')).to eq(262)
      expect(described_class.season_id_for('/tmp/d2026-abc/foo.json')).to eq(0)
    end

    it 'finds or creates one row per (season, base), keeping the source path current' do
      row = described_class.for_path!('/x/results.new/262/foo.json')
      again = described_class.for_path!('/x/results.new/262/foo-lt4.json')
      expect(again.id).to eq(row.id)
      expect(again.source_path).to eq('/x/results.new/262/foo-lt4.json')
      expect(described_class.where(season_id: 262, base: 'foo').count).to eq(1)
    end

    it 'validates the stage' do
      expect(FactoryBot.build(:ops_pipeline_source, stage: 'whatever')).not_to be_valid
      expect(FactoryBot.build(:ops_pipeline_source, stage: 'ready_to_commit')).to be_valid
    end

    describe 'the build lease' do
      let(:source) { FactoryBot.create(:ops_pipeline_source) }

      it 'is taken by one owner at a time until released or expired' do
        expect(source.acquire_lease!('req:a')).to be true
        expect(source.acquire_lease!('req:a')).to be true # (re-entrant)
        expect(source.acquire_lease!('job:b')).to be false
        expect(source.leased_by_other?('job:b')).to be true

        expect(source.release_lease!('job:b')).to be false
        expect(source.release_lease!('req:a')).to be true
        expect(source.acquire_lease!('job:b')).to be true
        expect(source.acquire_lease!('req:a', now: 11.minutes.from_now)).to be true # (expired)
      end
    end
  end

  describe Ops::PhaseVerdict do
    it 'is unique per (source, phase) and validates phase and status' do
      verdict = FactoryBot.create(:ops_phase_verdict, phase: 2, status: 'review')
      expect(FactoryBot.build(:ops_phase_verdict, pipeline_source: verdict.pipeline_source, phase: 2)).not_to be_valid
      expect(FactoryBot.build(:ops_phase_verdict, phase: 6)).not_to be_valid
      expect(FactoryBot.build(:ops_phase_verdict, status: 'nope')).not_to be_valid
    end

    it 'caps the stored issues and new entities' do
      expect(described_class.capped_issues(Array.new(250) { |i| { 'n' => i } }).size).to eq(described_class::ISSUES_CAP)
      capped = described_class.capped_new_entities('swimmers' => Array.new(300, {}), 'teams' => [])
      expect(capped['swimmers'].size).to eq(described_class::NEW_ENTITIES_CAP)
    end

    it 'is deleted with its source' do
      verdict = FactoryBot.create(:ops_phase_verdict)
      verdict.pipeline_source.destroy!
      expect(described_class.exists?(verdict.id)).to be false
    end
  end

  describe Ops::CommitReport do
    it 'requires a requesting user, a base and a known status' do
      expect(FactoryBot.build(:ops_commit_report, requested_by_user_id: nil)).not_to be_valid
      expect(FactoryBot.build(:ops_commit_report, source_base: nil)).not_to be_valid
      expect(FactoryBot.build(:ops_commit_report, status: 'done')).not_to be_valid
    end

    it 'is claimed (queued -> running) by one caller only' do
      report = FactoryBot.create(:ops_commit_report)
      expect(report.claim!(job_id: 'j1')).to be true
      expect(report).to be_running
      expect(described_class.find(report.id).claim!(job_id: 'j2')).to be false
      expect(report.reload.job_id).to eq('j1')
    end

    it 'records the progress and the final state without validations' do
      report = FactoryBot.create(:ops_commit_report, status: 'running')
      report.record_progress!(message: 'Committing Phase 3', current: 3, total: 6)
      expect(report.reload).to have_attributes(progress_message: 'Committing Phase 3', percent_done: 50)

      report.finish!(status: 'committed_archive_failed', archive_error: 'Errno::EACCES')
      expect(report.reload).to be_committed
      expect(report).to be_archive_failed
      expect(report.finished_at).to be_present
    end

    it 'maps the first error phase to its step key' do
      expect(FactoryBot.build(:ops_commit_report, first_error_phase: 3).first_error_step_key).to eq('swimmers')
      expect(FactoryBot.build(:ops_commit_report).first_error_step_key).to be_nil
    end
  end

  describe Ops::PipelineRun do
    it 'validates kind, origin and status, and detects a stale pending run' do
      expect(FactoryBot.build(:ops_pipeline_run, kind: 'nope')).not_to be_valid
      expect(FactoryBot.build(:ops_pipeline_run, origin: 'cron')).not_to be_valid
      run = FactoryBot.create(:ops_pipeline_run, status: 'running')
      expect(run.stale?).to be false
      expect(run.stale?(now: 31.minutes.from_now)).to be true
      run.record_progress!(message: 'Map swimmers', current: 5, total: 10)
      expect(run.reload).to have_attributes(progress: 5, total: 10, message: 'Map swimmers')
    end
  end
end
