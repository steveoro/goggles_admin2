# frozen_string_literal: true

require 'rails_helper'

# Phase 10 automation boundary (static): jobs, planners, the Season board services, the Data-Fix pipeline and the
# inbox may crawl, extract, build phases 1-5 and flag issues, but no code path from them leads to a commit or a push.
# The commit and push entry points are named only where an operator click starts them.
RSpec.describe 'Automation boundary' do # rubocop:disable RSpec/DescribeClass
  # Names that commit or push.
  FORBIDDEN = /\b(?:DataFixCommitJob|DataFix::CommitRunner|CommitRunner|Committers::Main|Outbox::PushJob|PushJob|commit_all)\b/ # rubocop:disable Lint/ConstantDefinitionInBlock,RSpec/LeakyConstantDeclaration

  # The automation side (scanned).
  let(:scanned_globs) do
    %w[app/jobs/**/*.rb app/services/season_board/**/*.rb app/services/data_fix/pipeline.rb app/services/data_fix/pipeline/**/*.rb
       app/services/data_fix/automation.rb app/services/inbox/**/*.rb app/controllers/season_board_controller.rb
       app/controllers/automation_controller.rb]
  end

  # Files allowed to name them: the two jobs themselves, and the failed-job list that refuses to retry them.
  let(:allowed) do
    {
      'app/jobs/data_fix_commit_job.rb' => nil, 'app/jobs/outbox/push_job.rb' => nil,
      'app/services/inbox/sources/failed_jobs.rb' => /PROTECTED_JOBS = /
    }
  end
  # The prepare path: the jobs, the pipeline and its solvers / populator / verifier / verdicts, the guards and the DB
  # sync gate they call, the board services, the PDF and category helpers.
  let(:prepare_path_globs) do
    %w[app/jobs/data_fix_prepare_job.rb app/jobs/pipeline_planner_job.rb app/jobs/manifest_extract_job.rb app/jobs/meeting_crawl_job.rb
       app/services/data_fix/**/*.rb app/strategies/import/**/*.rb app/services/drift/**/*.rb app/services/season_board/**/*.rb
       app/services/phase3/**/*.rb app/strategies/pdf_results/**/*.rb app/strategies/pdf_manifests/**/*.rb app/services/inbox/**/*.rb]
  end

  # [path, line number, line] of every non-comment line naming a forbidden constant.
  def offenses(globs)
    globs.flat_map { |glob| Rails.root.glob(glob) }.uniq.flat_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      file.readlines.each_with_index.filter_map do |line, index|
        code = line.chomp.sub(/#(?!\{).*\z/, '') # (comments may explain the boundary; '#{' is an interpolation)
        [path, index + 1, line.strip] if FORBIDDEN.match?(code)
      end
    end
  end

  it 'finds no commit or push entry point in the jobs, planners, board services, pipeline and inbox' do
    unexpected = offenses(scanned_globs).reject do |path, _number, line|
      allowed.key?(path) && (allowed[path].nil? || allowed[path].match?(line))
    end
    expect(unexpected).to eq([])
  end

  it 'enqueues DataFixCommitJob only from the commit controller and Outbox::PushJob only from the Outbox controller' do
    enqueues = offenses(%w[app/**/*.rb lib/**/*.rb]).select { |_path, _number, line| line.match?(/(?:DataFixCommitJob|PushJob)\.(?:perform|set)/) }
    expect(enqueues.map(&:first).uniq.sort).to eq(%w[app/controllers/data_fix/commits_controller.rb app/controllers/outbox_controller.rb])
  end

  it 'runs the commit (CommitRunner, Committers::Main, commit_all) only from the commit controller, the runner and the commit job' do
    runs = offenses(%w[app/**/*.rb lib/**/*.rb]).select { |_path, _number, line| line.match?(/CommitRunner\.new|Committers::Main\.new|\.commit_all/) }
    # (app/strategies/import/committers/main.rb defines commit_all itself)
    expect(runs.map(&:first).uniq.sort - ['app/strategies/import/committers/main.rb'])
      .to eq(%w[app/controllers/data_fix/commits_controller.rb app/jobs/data_fix_commit_job.rb app/services/data_fix/commit_runner.rb])
  end

  it 'makes no remote write from the prepare path: its only API call is the read-only DB sync GET of the drift gate' do
    lines = prepare_path_globs.flat_map { |glob| Rails.root.glob(glob) }.uniq.flat_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      file.readlines.each_with_index.filter_map do |line, index|
        code = line.chomp.sub(/#(?!\{).*\z/, '')
        [path, index + 1, code.strip] if code.match?(/APIProxy\.(?:call|post|put|patch|delete|execute)\b|Outbox::(?:Pusher|RemoteActions)/)
      end
    end
    # (documented exception: Drift::Fingerprint.remote, the light 'tools/db_fingerprint' GET of DataFix::Guards / Drift::Gate)
    expect(lines.map(&:first)).to eq(['app/services/drift/fingerprint.rb'])
    expect(lines.map(&:last)).to all(include('method: :get'))
  end

  it 'gives the prepare and planner jobs no retry handler' do
    expect(DataFixPrepareJob.rescue_handlers).to be_empty
    expect(PipelinePlannerJob.rescue_handlers).to be_empty
  end
end
