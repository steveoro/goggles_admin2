# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::Pipeline do
  let(:tmp_dir) { Dir.mktmpdir('pipeline-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: tmp_dir) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def write_phase(phase, data)
    PhaseFileManager.new(pipeline.phase_path(phase)).write!(data:, meta: { 'generator' => 'spec' })
    pipeline.reload!
  end

  # Phase 4 + flat phase 5 files stamped as built.
  def add_later_phases
    write_phase(4, 'sessions' => [{ 'session_order' => 1, 'events' => [{ 'key' => '50SL', 'session_order' => 1, 'event_type_id' => 1, 'id' => nil }] }])
    PhaseFileManager.new(pipeline.phase_path(5)).write_payload!('name' => 'phase5', 'programs' => [])
    pipeline.reload!
    [4, 5].each { |phase| pipeline.send(:stamp_built!, phase) }
    pipeline.reload!
  end

  def stub_recipe
    allow(DataFix::Pipeline::Recipes).to receive(:build) do |pipe, phase|
      PhaseFileManager.new(pipe.phase_path(phase)).write!(data: { 'rebuilt' => phase, 'teams' => [], 'swimmers' => [] }, meta: {})
      { notice: "built #{phase}" }
    end
  end

  describe 'edit markers' do
    it 'treats a stamped, untouched phase as not edited and a hand-edited one as edited' do
      expect(pipeline.edited?(2)).to be false
      data = PhaseFileManager.new(pipeline.phase_path(2)).data
      data['teams'].first['team_id'] = 1
      File.write(pipeline.phase_path(2), JSON.generate('_meta' => pipeline.phase_meta(2), 'data' => data))
      expect(pipeline.reload!.edited?(2)).to be true
    end

    it 'adopts a pre-existing file (no build stamp) as edited, and keeps it adopted on restamp' do
      adopted = pipeline_from_fixture('clean_fin', dir: File.join(tmp_dir, 'b'), stamped: false)
      expect(adopted.edited?(1)).to be true
      expect(adopted.adopted?(1)).to be true
      adopted.restamp!(1)
      expect(adopted.reload!.phase_meta(1).dig('built', 'by')).to eq('adopted')
      expect(adopted.edited?(1)).to be true
    end

    it 'ignores _meta-only writes (retry flag, overwrite metadata)' do
      meta = pipeline.phase_meta(5) if pipeline.phase_exists?(5)
      expect(meta).to be_nil
      payload = JSON.parse(File.read(pipeline.phase_path(1)))
      payload['_meta']['retry_needed'] = true
      File.write(pipeline.phase_path(1), JSON.generate(payload))
      expect(pipeline.reload!.edited?(1)).to be false
    end

    it 'records the operator edit (last actions) in the file and mirrors it in ops' do
      pipeline.summary
      expect(pipeline.mark_edited!(2, action: 'update_phase2_team', user_id: 7)).to be true
      edit = pipeline.reload!.phase_meta(2)['operator_edit']
      expect(edit).to include('user_id' => 7, 'actions' => ['update_phase2_team'])
      expect(pipeline.edited?(2)).to be true
      row = Ops::PhaseVerdict.find_by(pipeline_source: pipeline.source_row, phase: 2)
      expect(row.operator_edited_at).to be_present
      25.times { pipeline.mark_edited!(2, action: 'add_team') }
      expect(pipeline.reload!.phase_meta(2).dig('operator_edit', 'actions').size).to eq(described_class::MAX_EDIT_ACTIONS)
    end

    it 'invalidates the Season board summary on an edit' do
      allow(SeasonBoard::Snapshot).to receive(:invalidate!)
      pipeline.mark_edited!(1, action: 'update_phase1_meeting')
      expect(SeasonBoard::Snapshot).to have_received(:invalidate!).with(242).at_least(:once)
    end
  end

  describe '#settle!' do
    it 'writes the retry flag and the adopted stamp once, then never again' do
      adopted = pipeline_from_fixture('clean_fin', dir: File.join(tmp_dir, 'c'), stamped: false)
      path = adopted.phase_path(2)
      expect(adopted.settle!(2)).to be false
      expect(adopted.reload!.phase_meta(2)).to include('retry_needed' => false)
      expect(adopted.phase_meta(2).dig('built', 'by')).to eq('adopted')
      mtime = File.mtime(path)
      sleep(0.02)
      adopted.reload!.settle!(2)
      expect(File.mtime(path)).to eq(mtime)
    end
  end

  describe '#stale?' do
    before(:each) { add_later_phases }

    it 'is fresh right after the build' do
      expect((1..5).map { |phase| pipeline.stale?(phase) }).to all(be_empty)
    end

    it 'marks Phase 5 stale after a Phase 4 event edit (and only the phases depending on it)' do
      data = PhaseFileManager.new(pipeline.phase_path(4)).data
      data['sessions'].first['events'].first['event_type_id'] = 2
      write_phase(4, data)

      expect(pipeline.stale?(5)).to contain_exactly(include('upstream' => 4, 'key' => 'p4'))
      expect(pipeline.stale?(3)).to be_empty
      expect(pipeline.verdict(5, refresh: true)).to be_stale
    end

    it 'does not cascade an unrelated upstream edit (team name only)' do
      data = PhaseFileManager.new(pipeline.phase_path(2)).data
      data['teams'].first['editable_name'] = 'Renamed'
      write_phase(2, data)
      expect(pipeline.stale?(3)).to be_empty
      expect(pipeline.stale?(5)).to be_empty
    end

    it 'flags the new entities when the local DB was committed to since the build' do
      described_class.bump_db_generation!
      expect(pipeline.reload!.stale?(2)).to include(include('key' => 'db'))
      expect(pipeline.stale?(1)).to be_empty
    end
  end

  describe '#build_phase!' do
    it 'refuses an edited phase without force (EditedPhaseError) and rebuilds it with force' do
      stub_recipe
      pipeline.mark_edited!(2, action: 'add_team')
      expect { pipeline.build_phase!(2) }.to raise_error(described_class::EditedPhaseError)
      verdict = pipeline.build_phase!(2, force: true)
      expect(verdict).to be_a(DataFix::Verdict)
      meta = pipeline.reload!.phase_meta(2)
      expect(meta['operator_edit']).to be_nil
      expect(meta['built']).to include('by' => 'auto', 'inputs' => include('source', 'season'))
      expect(pipeline.edited?(2)).to be false
    end

    it 'raises MissingUpstreamError when an upstream phase file is missing (unless lenient)' do
      stub_recipe
      FileUtils.rm_f(pipeline.phase_path(2))
      expect { pipeline.reload!.build_phase!(3) }.to raise_error(described_class::MissingUpstreamError, /phase 2/)
      expect { pipeline.build_phase!(3, strict_upstream: false) }.not_to raise_error
    end

    it 'raises LeaseBusyError while another owner builds the source' do
      stub_recipe
      pipeline.source_row.acquire_lease!('job:other')
      expect { pipeline.build_phase!(1, force: true) }.to raise_error(described_class::LeaseBusyError)
      pipeline.source_row.release_lease!('job:other')
      expect { pipeline.build_phase!(1, force: true) }.not_to raise_error
      expect(pipeline.source_row.reload.lease_owner).to be_nil
    end

    it 'stores a failed verdict (with the message) when the recipe raises' do
      allow(DataFix::Pipeline::Recipes).to receive(:build).and_raise(StandardError, 'solver exploded')
      expect { pipeline.build_phase!(1, force: true) }.to raise_error(StandardError, 'solver exploded')
      row = Ops::PhaseVerdict.find_by(pipeline_source: pipeline.source_row, phase: 1)
      expect(row.status).to eq('failed')
      expect(row.counts['_message']).to include('solver exploded')
    end

    it 'builds a real Phase 2 without any ImportStatusChannel broadcast for a job (Null progress)' do
      File.write(pipeline.source_path, JSON.generate('layoutType' => 4, 'teams' => { 'Squadra Fixture Zq' => 'Squadra Fixture Zq' }))
      allow(ActionCable.server).to receive(:broadcast)
      pipeline.reload!.build_phase!(2, force: true)
      expect(ActionCable.server).not_to have_received(:broadcast)
      expect(pipeline.phase_data(2)['teams'].pluck('key')).to eq(['Squadra Fixture Zq'])
    end
  end

  describe '#prepare!' do
    before(:each) { stub_recipe }

    it 'builds the missing phases in order and skips the fresh ones' do
      FileUtils.rm_f(pipeline.phase_path(3))
      pipeline.reload!.prepare!(up_to: 3)
      expect(DataFix::Pipeline::Recipes).to have_received(:build).once.with(pipeline, 3)
    end

    it 'rebuilds a stale unedited phase but stops at a stale edited one (recorded as stale, reason edited)' do
      data = PhaseFileManager.new(pipeline.phase_path(1)).data
      data['header_date'] = '2025-03-09'
      write_phase(1, data)
      pipeline.send(:stamp_built!, 1)
      pipeline.reload!.mark_edited!(3, action: 'update_phase3_swimmer')

      pipeline.reload!.prepare!(up_to: 3)

      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)
      verdict = pipeline.verdict(3)
      expect(verdict).to be_stale
      expect(verdict.issues.pluck('code')).to include('edited_stale')
      expect(pipeline.last_prepare_stop).to eq(:edited)
    end

    it 'stops before a phase when +stop_if+ answers a reason, or when the deadline has passed (phase 10)' do
      FileUtils.rm_f(pipeline.phase_path(3))
      pipeline.reload!.prepare!(up_to: 3, stop_if: ->(phase) { :yielded if phase == 3 })
      expect(pipeline.last_prepare_stop).to eq(:yielded)
      expect(DataFix::Pipeline::Recipes).not_to have_received(:build)

      pipeline.reload!.prepare!(up_to: 3, deadline: 1.second.ago)
      expect(pipeline.last_prepare_stop).to eq(:deadline)
      pipeline.reload!.prepare!(up_to: 3)
      expect(pipeline.last_prepare_stop).to be_nil
    end
  end

  describe '#hold_lease! (phase 10: a prepare job keeps the lease for its whole run)' do
    it 'keeps the lease across the builds made inside and releases it at the end' do
      stub_recipe
      job_pipeline = described_class.for(pipeline.source_path, progress: Import::Progress::Null.new, actor: :auto, lease_owner: 'job:42')
      owners = []
      job_pipeline.hold_lease!(ttl: 25.minutes) do
        job_pipeline.build_phase!(1)
        owners << job_pipeline.source_row.reload.lease_owner
        job_pipeline.build_phase!(2)
        owners << job_pipeline.source_row.reload.lease_owner
      end
      expect(owners).to eq(%w[job:42 job:42])
      expect(job_pipeline.source_row.reload.lease_owner).to be_nil
    end

    it 'raises LeaseBusyError while someone else holds it' do
      pipeline.source_row.acquire_lease!('operator:1:x')
      job_pipeline = described_class.for(pipeline.source_path, progress: Import::Progress::Null.new, actor: :auto, lease_owner: 'job:42')
      expect { job_pipeline.hold_lease! { nil } }.to raise_error(described_class::LeaseBusyError)
    end
  end

  describe '#any_edited?' do
    it 'is true for adopted pre-existing files and for an operator edit, false for stamped files' do
      expect(pipeline.any_edited?).to be false
      expect(pipeline_from_fixture('clean_fin', dir: File.join(tmp_dir, 'adopted'), stamped: false).any_edited?).to be true
      pipeline.mark_edited!(1, action: 'update_phase1_meeting')
      expect(pipeline.reload!.any_edited?).to be true
    end
  end

  describe '#invalidate!' do
    before(:each) { add_later_phases }

    it 'deletes the unedited target phases after .orig backups, with their staging rows' do
      GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'pipeline-spec-mir', phase_file_path: pipeline.source_path)
      result = pipeline.invalidate!(phases: [3, 4, 5], reason: :categories_normalized)

      expect(result).to include(refused: false, deleted_temp_rows: 1)
      [3, 4, 5].each { |phase| expect(File).not_to exist(pipeline.phase_path(phase)) }
      expect(result[:backups].size).to eq(3)
      result[:backups].each { |backup| expect(File).to exist(backup) }
      expect(File).to exist(pipeline.phase_path(2))
    end

    it 'deletes nothing when a target phase is edited, and marks the source blocked' do
      pipeline.mark_edited!(4, action: 'update_phase4_event')
      result = pipeline.reload!.invalidate!(phases: [3, 4, 5], reason: :categories_normalized)

      expect(result).to include(refused: true, kept: [4])
      [3, 4, 5].each { |phase| expect(File).to exist(pipeline.phase_path(phase)) }
      expect(pipeline.source_row.reload).to have_attributes(stage: 'blocked', stage_reason: 'source_changed_under_edits')
      expect(pipeline.summary).to have_attributes(stage: 'blocked', source_changed: true)
    end

    it 'deletes nothing, even forced, while another build holds the lease (phase 10: a prepare job)' do
      pipeline.source_row.acquire_lease!('job:42')
      result = described_class.for(pipeline.source_path, progress: Import::Progress::Null.new)
                              .invalidate!(phases: [3, 4, 5], reason: :operator_discard, force: true)
      expect(result).to include(refused: true, leased: true)
      [3, 4, 5].each { |phase| expect(File).to exist(pipeline.phase_path(phase)) }
      expect(pipeline.source_row.reload.stage).not_to eq('blocked')
    end

    it 'deletes the edited phases too when forced (operator discard), clearing the block' do
      pipeline.mark_edited!(4, action: 'update_phase4_event')
      pipeline.reload!.invalidate!(phases: [3, 4, 5], reason: :categories_normalized)
      pipeline.reload!.invalidate!(phases: [3, 4, 5], reason: :operator_discard, force: true)
      [3, 4, 5].each { |phase| expect(File).not_to exist(pipeline.phase_path(phase)) }
      expect(pipeline.source_row.reload.source_changed_under_edits?).to be false
    end
  end

  describe '#summary' do
    it 'stores the stage and the verdicts, reusing the cached rows while the files do not change' do
      stub_valid_structure
      pipeline.relay_enrichment_count = 0
      summary = pipeline.summary
      expect(summary.stage).to eq('needs_review') # (phases 4 and 5 not built yet)
      expect(summary.review_phase).to eq(4)
      expect(pipeline.source_row.reload.stage).to eq('needs_review')
      expect(Ops::PhaseVerdict.where(pipeline_source: pipeline.source_row).count).to eq(5)

      allow(DataFix::Verdicts::Phase2).to receive(:new).and_call_original
      described_class.for(pipeline.source_path, progress: Import::Progress::Null.new).summary
      expect(DataFix::Verdicts::Phase2).not_to have_received(:new)
    end
  end

  describe '#refresh_new_entities!' do
    it 're-resolves only the nil-id rows (confirmed rows and ids left alone) and re-stamps the files' do
      team = FactoryBot.create(:team, name: 'Fixture Team 009', editable_name: 'Fixture Team 009')
      pipeline # (built before the commit below)
      described_class.bump_db_generation!
      expect(pipeline.reload!.stale?(2)).to include(include('key' => 'db'))

      result = pipeline.refresh_new_entities!

      expect(pipeline.reload!.stale?(2)).to be_empty
      teams = pipeline.reload!.phase_data(2)['teams'].index_by { |row| row['key'] }
      expect(teams['Fixture Team 009']['team_id']).to eq(team.id)
      expect(teams['Fixture Team 001']['team_id']).to eq(900_001)
      expect(result[:teams]).to be >= 1
      expect(pipeline.edited?(2)).to be false
    end
  end
end
