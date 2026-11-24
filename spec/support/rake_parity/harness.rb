# frozen_string_literal: true

require 'fileutils'
require 'rake'
require 'stringio'
require 'tmpdir'

#
# = RakeParity (phase 13)
#
# Recorded baselines of the operational rake tasks: console output + SQL scripts, run on goggles_test with fixed ids,
# simulate=1 and a stubbed stdin, inside the spec transaction (nothing is ever run on the DB: simulate), with
# SCRIPT_OUTPUT_DIR in a temporary data root (never the real crawler/data).
#
# The baselines in spec/support/rake_parity/baselines/*.txt were recorded with the task bodies BEFORE the phase-13
# conversion (thin Maintenance::RakeRunner callers); the *_parity_spec.rb files under spec/tasks replay the same cases
# on the converted tasks and compare the normalized text. Allowed differences (normalized away): the temporary data
# root, the 'NNNN-' prefix and the Outbox seq, '-- Generated:' timestamps and run durations. Ids of rows created by a
# case are replaced by named tokens (<BADGE_A>, ...).
#
# Re-record (only on purpose: e.g. after goggles_test was reloaded with a new dump, the old bodies are gone, so a
# re-record pins the converted tasks): RAKE_PARITY_RECORD=1 bundle exec rspec spec/tasks/*_parity_spec.rb
#
module RakeParity
  BASELINE_DIR = Rails.root.join('spec/support/rake_parity/baselines')

  # Every ENV option read by the converted tasks (cleared before and after each run).
  ENV_KEYS = %w[src dest index simulate skip_columns force keep_as_alias keep_dest_columns keep_dest_category keep_dest_team
                autofix season possible src_team dest_team meeting full_report badge team nuke_team swimmer meeting_id
                season_id stop_at_events limit remove source mrr presence list_teams page last7].freeze

  # output: console text; exit_status: nil (no exit) or the SystemExit status; scripts: Array of [rel_path, bytes].
  Run = Data.define(:output, :exit_status, :scripts)

  module_function

  def record? = ENV['RAKE_PARITY_RECORD'] == '1'

  # Normalized text of +text+ (see the module notes).
  def normalize(text, data_root:, tokens: {})
    out = text.to_s.dup
    out = out.gsub(data_root.to_s, '<DATA_ROOT>')
    out = out.gsub(%r{(results\.new/[\w.-]+/)\d{4}-}, '\1NNNN-')
    out = out.gsub(%r{(results\.new/)\d{4}-}, '\1NNNN-')
    out = out.gsub(/(Generating file ')\d{4}-/, '\1NNNN-')
    out = out.gsub(/seq \d+/, 'seq N')
    out = out.gsub(/^(-- Generated: )[^\r\n]*/, '\1<TIME>')
    out = out.gsub(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?: UTC| [+-]\d{4})?/, '<TIME>')
    out = out.gsub(/Done in [\d.]+ s/, 'Done in <T> s')
    out = out.gsub(/Total time for (\d+)x runs: [\d.e-]+"/, 'Total time for \1x runs: <T>"')
    tokens.each { |name, id| out = out.gsub(/(?<![\d.])#{Regexp.escape(id.to_s)}(?!\d)/, "<#{name}>") }
    out
  end

  # The baseline document of a run (exit status, output, then each script).
  def document(run, data_root:, tokens: {})
    parts = ["## exit: #{run.exit_status.inspect}\n", "## output\n", normalize(run.output, data_root:, tokens:)]
    run.scripts.each do |rel_path, bytes|
      parts << "\n## script #{normalize(rel_path, data_root:, tokens:)}\n" << normalize(bytes, data_root:, tokens:)
    end
    parts.join
  end

  def baseline_path(name) = BASELINE_DIR.join("#{name}.txt")

  # [output, [[rel_path, sql], ...]] of a stored baseline document.
  def baseline_parts(name)
    output, *scripts = File.binread(baseline_path(name)).force_encoding(Encoding::UTF_8).split("\n## script ")
    [output.sub(/\A## exit: [^\n]*\n## output\n/, ''), scripts.map { |part| part.split("\n", 2) }]
  end

  # == RSpec helpers (included with the :rake_parity metadata)
  module Helpers
    # Runs +task_name+ with +env+ (String values) and +stdin+ (text); SCRIPT_OUTPUT_DIR is <data_root>/results.new.
    def rake_parity_run(task_name, data_root:, env: {}, stdin: '')
      Rails.application.load_tasks unless Rake::Task.task_defined?(task_name)
      stub_const('SCRIPT_OUTPUT_DIR', data_root.join('results.new'))
      reenable_with_prerequisites(Rake::Task[task_name])
      output, status = with_rake_env(env) { capture_rake_io(stdin) { Rake::Task[task_name].invoke } }
      scripts = Dir.glob(data_root.join('results.new/**/*.sql').to_s).map do |path|
        [Pathname.new(path).relative_path_from(data_root).to_s, File.binread(path).force_encoding(Encoding::UTF_8)]
      end
      RakeParity::Run.new(output:, exit_status: status, scripts:)
    end

    # Records (RAKE_PARITY_RECORD=1) or compares the baseline +name+ of a run (+sorted+: the output lines sorted, for
    # the tasks listing rows in an order with ties).
    def expect_rake_parity(name, task_name, data_root:, env: {}, stdin: '', tokens: {}, sorted: false) # rubocop:disable Metrics/ParameterLists
      run = rake_parity_run(task_name, data_root:, env:, stdin:)
      run = run.with(output: run.output.lines.sort.join) if sorted
      document = RakeParity.document(run, data_root:, tokens:)
      path = RakeParity.baseline_path(name)
      if RakeParity.record?
        FileUtils.mkdir_p(path.dirname)
        File.binwrite(path, document)
      else
        expect(path).to exist, "missing baseline #{path.basename} (record it with RAKE_PARITY_RECORD=1)"
        expect(document).to eq(File.binread(path).force_encoding(Encoding::UTF_8))
      end
      run
    end

    private

    def reenable_with_prerequisites(task)
      task.reenable
      task.prerequisite_tasks.each { |prerequisite| reenable_with_prerequisites(prerequisite) }
    end

    def with_rake_env(env)
      RakeParity::ENV_KEYS.each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key.to_s] = value.to_s }
      yield
    ensure
      RakeParity::ENV_KEYS.each { |key| ENV.delete(key) }
    end

    # [stdout text, exit status or nil]
    def capture_rake_io(stdin)
      buffer = StringIO.new
      original_out = $stdout
      original_in = $stdin
      $stdout = buffer
      $stdin = StringIO.new(stdin.to_s)
      status = nil
      begin
        yield
      rescue SystemExit => e
        status = e.status
      end
      [buffer.string.dup.force_encoding(Encoding::UTF_8), status]
    ensure
      $stdout = original_out
      $stdin = original_in
    end
  end
end

RSpec.configure do |config|
  config.include(RakeParity::Helpers, :rake_parity)
end
