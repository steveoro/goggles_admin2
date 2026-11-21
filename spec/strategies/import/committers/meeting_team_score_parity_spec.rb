# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'tmpdir'

# = Team-score parity: v2 Data-Fix flow vs. frozen legacy output
#
# Builds the Phase 1-5 files with the v2 solvers from the same PDF-derived LT2 fixture used for
# the legacy baseline (spec/fixtures/import/pdf-teamrank-lt2.json, copied into a temporary
# "<season_id>/" folder), commits them with Import::Committers::Main#commit_all inside the
# example transaction and compares the resulting meeting_team_scores with
# spec/fixtures/import/team_scores_legacy_expected.json (MacroSolver + MacroCommitter output).
#
RSpec.describe Import::Committers::MeetingTeamScore, type: :strategy do
  let(:fixture_path) { Rails.root.join('spec/fixtures/import/pdf-teamrank-lt2.json') }
  let(:expected_rows) { JSON.parse(Rails.root.join('spec/fixtures/import/team_scores_legacy_expected.json').read)['team_scores'] }
  let(:tmp_dir) { Dir.mktmpdir }
  let(:resolver) { DataFix::SourceResolver.new }
  let(:lt2_path) do
    season_dir = File.join(tmp_dir, JSON.parse(File.read(fixture_path))['season_id'].to_s)
    FileUtils.mkdir_p(season_dir)
    File.join(season_dir, 'pdf-teamrank.json').tap { |path| FileUtils.cp(fixture_path, path) }
  end

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def phase_path(source_path, phase)
    resolver.default_phase_path_for(source_path, phase)
  end

  # Runs the v2 phase builders (as the Data-Fix review actions do) and returns the working source path.
  def build_v2_phase_files!
    source_path = resolver.resolve_working_source_path(lt2_path)
    season = resolver.detect_season_from_pathname(source_path)
    lt_format = resolver.detect_layout_type(source_path)
    categories_cache = PdfResults::CategoriesCache.cached_for(season)

    Import::Solvers::Phase1Solver.new(season:).build!(source_path:, lt_format:)
    review_new_meeting!(phase_path(source_path, 1), season)
    Import::Solvers::TeamSolver.new(season:).build!(source_path:, lt_format:)
    Import::Solvers::SwimmerSolver.new(season:, categories_cache:).build!(
      source_path:, lt_format:, phase1_path: phase_path(source_path, 1), phase2_path: phase_path(source_path, 2)
    )
    Import::Solvers::EventSolver.new(season:).build!(source_path:, lt_format:, phase1_path: phase_path(source_path, 1))
    build_phase5!(source_path, season, lt_format)
    source_path
  end

  def build_phase5!(source_path, season, lt_format)
    Import::Solvers::ResultSolver.new(season:).build!(source_path:, lt_format:)
    Import::Phase5Populator.new(
      source_path:, phase1_path: phase_path(source_path, 1), phase2_path: phase_path(source_path, 2),
      phase3_path: phase_path(source_path, 3), phase4_path: phase_path(source_path, 4)
    ).populate!
  end

  # Emulates the operator's Step 1 review of a new meeting & pool: the solver leaves some required
  # columns blank (meeting values are the same ones the legacy solver computed on its own).
  def review_new_meeting!(phase1_path, season)
    pfm = PhaseFileManager.new(phase1_path)
    data = pfm.data
    edition, _name_no_edition, edition_type_id = GogglesDb::Normalizers::CodedName.edition_split_from(data['name'])
    data.merge!(
      'code' => GogglesDb::Normalizers::CodedName.for_meeting(data['name'], data['address1']),
      'header_year' => season.header_year,
      'edition' => edition,
      'edition_type_id' => edition_type_id,
      'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID
    )
    Array(data['meeting_session']).each do |session|
      session['swimming_pool'].merge!('nick_name' => 'romacomunale25', 'lanes_number' => 8) if session['swimming_pool'].is_a?(Hash)
    end
    pfm.write!(data:, meta: pfm.meta)
  end

  def frozen_attributes_for(row)
    {
      'rank' => row.rank,
      'team_id' => row.team_id,
      'team_affiliation_id' => row.team_affiliation_id,
      'season_id' => row.season_id,
      'sum_individual_points' => row.sum_individual_points.to_f,
      'sum_relay_points' => row.sum_relay_points.to_f,
      'sum_team_points' => row.sum_team_points.to_f,
      'meeting_points' => row.meeting_points.to_f,
      'meeting_relay_points' => row.meeting_relay_points.to_f,
      'meeting_team_points' => row.meeting_team_points.to_f,
      'season_points' => row.season_points.to_f,
      'season_relay_points' => row.season_relay_points.to_f,
      'season_team_points' => row.season_team_points.to_f
    }
  end

  it 'commits the same team scores as the legacy flow', :aggregate_failures do
    source_path = build_v2_phase_files!
    expect(source_path).to end_with('-lt4.json')

    phase2_data = JSON.parse(File.read(phase_path(source_path, 2)))['data']
    expect(phase2_data['team_scores'].pluck('rank')).to eq([1, 2, 3, 4, 5])
    phase4_event_codes = JSON.parse(File.read(phase_path(source_path, 4)))['data']['sessions']
                             .flat_map { |session| Array(session['events']) }.pluck('key')
    expect(phase4_event_codes).not_to include('EVENT') # no junk "Overall Team Ranking" / "Overall Stats" events

    committer = Import::Committers::Main.new(
      source_path:,
      phase1_path: phase_path(source_path, 1), phase2_path: phase_path(source_path, 2),
      phase3_path: phase_path(source_path, 3), phase4_path: phase_path(source_path, 4),
      phase5_path: phase_path(source_path, 5),
      log_path: File.join(tmp_dir, 'commit.log')
    )
    stats = committer.commit_all

    expect(stats[:errors]).to be_empty
    expect(stats[:team_scores_created]).to eq(5)
    expect(stats[:team_scores_skipped]).to eq(0)
    meeting_id = committer.instance_variable_get(:@meeting).id
    rows = GogglesDb::MeetingTeamScore.where(meeting_id:).order(:rank).map { |row| frozen_attributes_for(row) }
    expect(rows).to eq(expected_rows)
    expect(committer.sql_log.grep(/INSERT INTO `meeting_team_scores`/).size).to eq(5)
  end
end
