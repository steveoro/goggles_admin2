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
       app/controllers/automation_controller.rb app/services/sources.rb app/services/sources/**/*.rb app/controllers/sources/**/*.rb
       app/services/crawler/**/*.rb app/strategies/pdf_manifests/**/*.rb app/strategies/pdf_results/scan_*.rb
       app/services/federnuoto_watch.rb app/services/federnuoto_watch/**/*.rb app/controllers/federnuoto_watch_controller.rb]
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
       app/services/phase3/**/*.rb app/strategies/pdf_results/**/*.rb app/strategies/pdf_manifests/**/*.rb app/services/inbox/**/*.rb
       app/services/federnuoto_watch/**/*.rb app/jobs/federnuoto_watch_job.rb app/jobs/season_recheck_job.rb app/jobs/source_crawl_job.rb]
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

  # Phase 15: the manual crawls, PDF scans and manifest extractions are queued only by an operator click (the Sources
  # controllers), the Season board scheduler and the Sources manifest queue: never by a commit or push path.
  it 'enqueues SourceCrawlJob, PdfScanJob and ManifestExtractJob only from the Sources pages and the board scheduler' do
    enqueues = Rails.root.glob('{app,lib}/**/*.rb').flat_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      file.readlines.filter_map do |line|
        code = line.chomp.sub(/#(?!\{).*\z/, '')
        path if code.match?(/\b(?:SourceCrawlJob|PdfScanJob|ManifestExtractJob)\b.*\.perform_(?:later|now)\b/)
      end
    end
    expect(enqueues.uniq.sort).to eq(%w[app/controllers/sources/crawls_controller.rb app/controllers/sources/pdfs_controller.rb
                                        app/services/season_board/scheduler.rb app/services/sources/manifest_queue.rb])
    expect([SourceCrawlJob, PdfScanJob, ManifestExtractJob].map(&:rescue_handlers)).to all(be_empty)
  end

  # 0.10.103: the calendar automation chain (FIN change -> 'Eventi' calendar crawl -> meeting crawls -> prepares ->
  # automatic dismissal of the alert) only crawls and acknowledges the watcher state.
  describe 'the calendar automation chain (0.10.103)' do
    let(:chain_files) do
      %w[app/services/season_board/calendar_planner.rb app/services/season_board/change_chain.rb app/services/season_board/crawl_planner.rb
         app/services/season_board/scheduler.rb app/services/federnuoto_watch/parity.rb app/services/federnuoto_watch/parity_check.rb
         app/services/federnuoto_watch/acknowledge.rb app/services/federnuoto_watch/progress.rb app/services/inbox/sources/fin_notice.rb
         app/jobs/pipeline_planner_job.rb app/jobs/federnuoto_watch_job.rb app/jobs/season_recheck_job.rb]
    end

    # Non-comment lines of the file matching the regexp.
    def code_lines(path, regexp)
      Rails.root.join(path).readlines.map { |line| line.chomp.sub(/#(?!\{).*\z/, '') }.grep(regexp)
    end

    it 'never names the calendar_results kind (processing a whole calendar stays an operator click)' do
      expect(chain_files.flat_map { |path| code_lines(path, /calendar_results/) }).to eq([])
      expect(SourceCrawlJob::AUTO_KINDS).to eq(%w[calendar])
    end

    it 'names no commit, push or maintenance apply entry point, and writes no local calendar or meeting' do
      apply = /\b(?:DataFixCommitJob|CommitRunner|Committers::Main|PushJob|commit_all|Maintenance::RunJob|RunJob|SqlRunner|CalendarLinker|Outbox::Writer)\b/
      expect(chain_files.flat_map { |path| code_lines(path, apply).map { |line| [path, line.strip] } }).to eq([])
      db_models = /GogglesDb::(?!Season\b)\w+/
      expect(chain_files.flat_map { |path| code_lines(path, db_models).map { |line| [path, line.strip] } }).to eq([])
    end

    it 'enqueues the calendar crawl only through the Scheduler, and the meeting crawls only through Scheduler.crawl!' do
      enqueues = chain_files.flat_map { |path| code_lines(path, /\b(?:SourceCrawlJob|MeetingCrawlJob)\b.*\.perform_(?:later|now)\b/).map { path } }
      expect(enqueues.uniq).to eq(%w[app/services/season_board/scheduler.rb])
    end

    it 'can never request the calendar_results kind: the default Eventi request, the Scheduler and an automatic SourceCrawlJob' do
      season = GogglesDb::Season.last
      expect(Sources::CrawlRequest.eventi_calendar(season).kind).to eq('calendar')
      FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
      allow(SeasonBoard::Notifier).to receive(:ping)
      expect { SeasonBoard::Scheduler.calendar_crawl!(season:, origin: :auto) }
        .to have_enqueued_job(SourceCrawlJob).with(hash_including(kind: 'calendar', origin: 'auto'))

      crawler = instance_double(CrawlerClient)
      SourceCrawlJob.crawler_client_factory = -> { crawler }
      key = SeasonBoard::ActivityLog.source_key('crawl:calendar_results', '/x.csv')
      SourceCrawlJob.perform_now(kind: 'calendar_results', season_id: season.id, file_path: '/x.csv', key:, origin: 'auto')
      expect(SeasonBoard::ActivityLog.new.entry(key, :crawl))
        .to have_attributes(status: :failed, message: I18n.t('sources.crawl.auto_kind_refused', kind: 'calendar_results'))
    ensure
      SourceCrawlJob.crawler_client_factory = -> { CrawlerClient.new }
      FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    end

    it 'gives the watcher and the daily re-check jobs no retry handler' do
      expect([FedernuotoWatchJob, SeasonRecheckJob].map(&:rescue_handlers)).to all(be_empty)
    end
  end
end
