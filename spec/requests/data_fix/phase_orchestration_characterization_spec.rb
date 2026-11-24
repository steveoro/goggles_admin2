# frozen_string_literal: true

require 'rails_helper'
require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'

module PhaseChar
  FIXTURES_DIR = Rails.root.join('spec/fixtures/import').freeze
  BASENAME = 'sample-200RA-l4'

  STAGING_TABLES = [
    GogglesDb::DataImportMeetingIndividualResult, GogglesDb::DataImportLap,
    GogglesDb::DataImportMeetingRelayResult, GogglesDb::DataImportMeetingRelaySwimmer, GogglesDb::DataImportRelayLap
  ].freeze

  # [review action, v2 flag param, phase number]
  STEPS = [
    [:review_sessions, 'phase_v2', 1],
    [:review_teams, 'phase2_v2', 2],
    [:review_swimmers, 'phase3_v2', 3],
    [:review_events, 'phase4_v2', 4],
    [:review_results, 'phase5_v2', 5]
  ].freeze

  # Digests (first 16 hex chars of the SHA256 of the re-generated JSON of the 'data' section)
  # of each phase file as rebuilt from the source file only:
  COLD_START_DATA_DIGESTS = {
    1 => '444e8bc663ed19cb', 2 => '8a92585a5ec8c5a7', 3 => '20dc985325aef8ec',
    4 => 'f8a8c728148bdbfc', 5 => '74234e98afe7498f'
  }.freeze
  # Phase 5 staging rows (individual results, laps, relay results, relay swimmers, relay laps) after the cold start:
  COLD_START_STAGING_COUNTS = [298, 893, 0, 0, 0].freeze
end

# = Characterization of the Data-Fix v2 per-phase orchestration
#
# Pins down what each review GET (+ v2 flag) does today to the phase files and to the
# Phase 5 staging tables, working on a temporary copy of the "sample-200RA-l4" fixtures
# (nothing is ever written into spec/fixtures or crawler/data).
#
# Whoever refactors the orchestration (Phase 09) must keep this spec green *unchanged*.
#
# What is recorded:
# - cold start (source file only): the first GET of each step builds its phase file and redirects
#   to itself; the second GET renders (200). Which files are written, and the digest of the
#   *data* section of each rebuilt phase file; plus the number of staged data_import_* rows.
# - warm start (all phase files already there): each GET renders (200) and re-writes only the
#   phase file of its own step (metadata only: the data digest is unchanged); nothing is staged.
# - no v2 flag: the v2 flags are optional, so the GET behaves exactly like the warm-start one.
#
# NOTE: the cold-start digests & row counts depend on the (anonymized) test DB content the fixtures
# are synchronized with (see spec/fixtures/import/README.md).
RSpec.describe 'Data-Fix phase orchestration (characterization)' do
  include AdminSignInHelpers

  let(:tmp_root) { Dir.mktmpdir('phase-orchestration-') }
  let(:work_dir) { File.join(tmp_root, '242') } # (the season ID is read from the folder name)
  let(:marked_mtimes) { {} }
  let(:source_path) { File.join(work_dir, "#{PhaseChar::BASENAME}.json") }

  before(:each) do
    sign_in_admin(prepare_admin_user)
    FileUtils.mkdir_p(work_dir)
    FileUtils.cp(PhaseChar::FIXTURES_DIR.join("#{PhaseChar::BASENAME}.json"), work_dir)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  def phase_path(phase)
    File.join(work_dir, "#{PhaseChar::BASENAME}-phase#{phase}.json")
  end

  def copy_fixture_phase_files
    FileUtils.cp(Dir[PhaseChar::FIXTURES_DIR.join("#{PhaseChar::BASENAME}-phase*.json")], work_dir)
  end

  def data_digest(path)
    json = JSON.parse(File.read(path))
    Digest::SHA256.hexdigest(JSON.generate(json['data']))[0, 16]
  end

  # Remembers the current mtimes (so that any further write can be detected by #files_written_since_mark).
  # (The files are deliberately not touched: some orchestration steps may depend on their natural ordering.)
  def mark_files!
    sleep(0.02) # (stay clear of the file system timestamp granularity)
    marked_mtimes.replace(Dir.glob(File.join(work_dir, '*')).index_with { |path| File.mtime(path) })
  end

  def files_written_since_mark
    Dir.glob(File.join(work_dir, '*')).reject { |path| marked_mtimes[path] == File.mtime(path) }.map { |path| File.basename(path) }.sort
  end

  def staging_counts
    PhaseChar::STAGING_TABLES.map(&:count)
  end

  def review_path_for(action, flag)
    send(:"#{action}_path", file_path: source_path, flag => 1)
  end

  context 'with the source file only (cold start)' do
    it 'builds each phase file on the first GET (redirecting to itself) and renders on the second one' do
      PhaseChar::STEPS.each do |action, flag, phase|
        mark_files!
        get(review_path_for(action, flag))

        expect(response).to have_http_status(:found), "#{action}: expected a redirect after the build"
        expect(response.location).to include(action.to_s)
        expect(files_written_since_mark).to eq(["#{PhaseChar::BASENAME}-phase#{phase}.json"]), "#{action}: unexpected files written on build"
        expect(data_digest(phase_path(phase))).to eq(PhaseChar::COLD_START_DATA_DIGESTS[phase]), "#{action}: data digest of the rebuilt phase file"

        mark_files!
        get(review_path_for(action, flag))

        expect(response).to have_http_status(:ok), "#{action}: expected the review page"
        expect(files_written_since_mark).to eq(["#{PhaseChar::BASENAME}-phase#{phase}.json"]), "#{action}: unexpected files written on render"
        expect(data_digest(phase_path(phase))).to eq(PhaseChar::COLD_START_DATA_DIGESTS[phase]), "#{action}: data digest changed on render"
      end
    end

    it 'stages the Phase 5 results & laps into the data_import_* tables while building phase 5' do
      PhaseChar::STEPS.first(4).each do |action, flag, _phase|
        get(review_path_for(action, flag)) # (build)
        expect(staging_counts).to eq([0, 0, 0, 0, 0])
      end
      get(review_path_for(:review_results, 'phase5_v2'))

      expect(response).to have_http_status(:found)
      expect(staging_counts).to eq(PhaseChar::COLD_START_STAGING_COUNTS)
      expect(GogglesDb::DataImportMeetingIndividualResult.distinct.pluck(:phase_file_path)).to eq([source_path])
    end
  end

  context 'with all the phase files already in place (warm start)' do
    before(:each) { copy_fixture_phase_files }

    PhaseChar::STEPS.each do |action, flag, phase|
      it "GET #{action} renders, re-writing only the phase #{phase} file (metadata only) and staging nothing" do
        digests_before = (1..5).index_with { |n| data_digest(phase_path(n)) }
        mark_files!

        get(review_path_for(action, flag))

        expect(response).to have_http_status(:ok)
        expect(files_written_since_mark).to eq(["#{PhaseChar::BASENAME}-phase#{phase}.json"])
        expect((1..5).index_with { |n| data_digest(phase_path(n)) }).to eq(digests_before)
        expect(staging_counts).to eq([0, 0, 0, 0, 0])
      end
    end
  end

  context 'without the v2 flag' do
    before(:each) { copy_fixture_phase_files }

    PhaseChar::STEPS.each do |action, _flag, phase|
      it "GET #{action} renders the v2 page like the flagged request (the v2 flag is optional)" do
        digests_before = (1..5).index_with { |n| data_digest(phase_path(n)) }
        mark_files!

        get(send(:"#{action}_path", file_path: source_path))

        expect(response).to have_http_status(:ok)
        expect(files_written_since_mark).to eq(["#{PhaseChar::BASENAME}-phase#{phase}.json"])
        expect((1..5).index_with { |n| data_digest(phase_path(n)) }).to eq(digests_before)
        expect(staging_counts).to eq([0, 0, 0, 0, 0])
      end
    end
  end
end
