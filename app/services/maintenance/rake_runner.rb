# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::RakeRunner
  #
  # Runs an operational rake task as a thin caller of the maintenance operations (phase 13): each task body in
  # lib/tasks is one call, and its adapter (Maintenance::RakeTasks, same texts, prompts and exits as the former body)
  # uses this runner to:
  # - plan with an Ops::OperationRun (origin 'rake') run INLINE by Maintenance::Executor (the terminal user is the
  #   operator: no job), then print what the strategy printed, unchanged;
  # - keep the task's prompt between the plan and the write (#confirm?);
  # - write the script: simulate=1 (the default) => mode 'script_only' (registered held 'not_applied_locally', nothing
  #   run); simulate=0 => the DB sync gate first (Drift::Gate, scope :rake: red stops unless force=1, the other
  #   warnings are printed, and acknowledged since the operator reads them), then mode 'apply' (child of the dry run:
  #   re-plan, same digest, LocalDb::SqlRunner, then the Outbox, the health re-run, ...);
  # - stop where the task stopped (#stop!: the rake caller exits with that status when there is one).
  #
  # The scripts keep the bytes of the former tasks (lines joined with "\r\n" and a final newline) and their names; the
  # Outbox allocates the number (an explicit index= stays the file prefix), the folder is results.new/misc (the season
  # folder for the standard timings). Read-only checks (Maintenance::Inspector) plan without any run row.
  #
  # The ops DB is required for the tasks writing a script (their runs are the history of /operations).
  #
  # == Usage (lib/tasks)
  #   status = Maintenance::RakeRunner.call('merge:swimmer', data_root: SCRIPT_OUTPUT_DIR.dirname)
  #   exit(status) if status
  #
  class RakeRunner # rubocop:disable Metrics/ClassLength
    # Stops the task: +status+ is the exit status of the former body (nil when it just ended).
    class Stop < StandardError
      attr_reader :status

      def initialize(status = nil)
        @status = status
        super("rake task stopped (#{status.inspect})")
      end
    end

    # An error the former body did not rescue (rake prints "rake aborted!" and exits 1, as before).
    class TaskError < StandardError; end

    # Prints the two lines of the former 'execute_sql_file' around the local apply.
    class PrintingSqlRunner
      def initialize(out, runner)
        @out = out
        @runner = runner
      end

      def call(path:)
        @out.puts('--> Executing script...')
        result = @runner.call(path:)
        @out.puts("--> Done in #{result.duration.to_f.round(2)} s.") if result.success?
        result
      end
    end

    # The bytes of the former rake scripts ('sql_log_array.join("\r\n")' plus the final newline of 'f.puts').
    SCRIPT_TEXT = lambda do |plan|
      content = plan.sql_lines.join("\r\n")
      content.end_with?("\n") ? content : "#{content}\n"
    end

    # The ENV options stored in the Outbox origin of a rake script.
    ORIGIN_ARGS = %w[season src dest index simulate meeting team badge swimmer meeting_id season_id].freeze

    attr_reader :task_name, :env, :out, :input, :data_root

    # == Params
    # - task_name: 'merge:swimmer', ... (Maintenance::RakeTasks::TASKS);
    # - env (ENV), out ($stdout), input ($stdin): the task options and its terminal;
    # - data_root: crawler data root of the scripts (the tasks pass SCRIPT_OUTPUT_DIR.dirname);
    # - sql_runner / gate: LocalDb::SqlRunner and Drift::Gate (specs: stand-ins).
    # Returns the exit status of the task (nil when it just ended).
    def self.call(task_name, env: ENV, out: $stdout, input: $stdin, data_root: Outbox.data_root, sql_runner: LocalDb::SqlRunner, # rubocop:disable Metrics/ParameterLists
                  gate: Drift::Gate)
      new(task_name, env:, out:, input:, data_root:, sql_runner:, gate:).call
    end

    def initialize(task_name, env:, out:, input:, data_root:, sql_runner:, gate:) # rubocop:disable Metrics/ParameterLists
      @task_name = task_name.to_s
      @env = env
      @out = out
      @input = input
      @data_root = Pathname.new(data_root)
      @sql_runner = sql_runner
      @gate = gate
    end

    def call
      Maintenance::RakeTasks.fetch(task_name).new(self).call
      nil
    rescue Stop => e
      e.status
    end

    # == Terminal

    # Prints each line (Kernel#puts semantics).
    def say(*lines) = lines.empty? ? out.puts : out.puts(*lines)

    # Prints +text+ as it is (the captured output of a strategy).
    def write(text) = out.print(text.to_s)

    def stop!(status = nil) = raise(Stop, status)

    # The task's own prompt; true when the answer is 'y'.
    def confirm?(prompt)
      out.print(prompt)
      input.gets&.chomp&.downcase == 'y'
    end

    # == Options

    def simulate? = env['simulate'] != '0'
    def force? = env['force'] == '1'

    # The folder printed as 'dest. folder' (the former SCRIPT_OUTPUT_DIR).
    def script_output_dir = data_root.join(Outbox::NEW_DIR)

    # The number the former task printed or passed on (index=, else the next Outbox number; nothing is allocated).
    def file_index = env['index'].present? ? env['index'].to_i : (Outbox::Sequence.current_max(data_root:) + 1)

    # true / nil (never false: the operation flags).
    def flag(value) = value ? true : nil

    # == Operations

    # The dry run of +key+ with +params+ (an Executor, already run).
    def preview(key, params) = execute(key, params, mode: 'preview')

    # Script only: registered held 'not_applied_locally', nothing run locally.
    def script_only(key, params, script_name: nil) = execute(key, params, mode: 'script_only', script_name:)

    # The apply of +preview+ (an Executor of a succeeded dry run) after the DB sync gate.
    def apply(key, params, preview:, script_name: nil)
      check_gate!
      execute(key, params, mode: 'apply', parent: preview.run, script_name:)
    end

    # Writes the script: script only with simulate=1, else the apply (after a dry run, given or made now).
    def write_script(key, params, preview: nil, script_name: nil)
      return script_only(key, params, script_name:) if simulate?

      apply(key, params, preview: preview || self.preview(key, params), script_name:)
    end

    # A read-only plan (Maintenance::Inspector, or a dry run without history): the Operation, after #plan.
    def inspect_plan(key, params)
      operation = Maintenance::Registry.fetch(key).new(**params.compact)
      [operation, operation.plan]
    end

    # Prints the outcome of a written script (the lines of the former 'process_sql_file'), or stops on a refusal or
    # a failure.
    def report_script!(executor, refused: {})
      run = executor.run
      return report_refusal!(run, refused) if run.refused?

      report_failure!(run) if run.failed?
      say("\r\nFile '#{data_root.join(run.summary_hash['sql_rel_path'].to_s)}' saved (Outbox: #{outbox_state(run)}).")
      return unless run.script_only?

      say("\r\n\t\t>>> NOTHING WAS DONE TO THE DB: THIS WAS JUST A SIMULATION <<<\r\n")
      say("--> The script stays HELD in the Outbox until applied ('Apply locally') or re-run with 'simulate=0'.")
    end

    # The DB sync gate of a local apply (once per task): a red verdict stops (unless force=1), any other warning is
    # printed.
    def check_gate!
      return if @gate_checked

      gate = @gate.check(scope: :rake, acknowledged: true, force: force?)
      unless gate.allowed?
        say(I18n.t('db_sync.gate.rake_blocked', summary: gate.summary))
        stop!(nil)
      end
      say(I18n.t('db_sync.gate.rake_warning', summary: gate.summary)) unless gate.ok?
      @gate_checked = true
    end

    private

    # The stop of a failed run, with what really happened to the local DB and the Outbox (exit 1).
    def report_failure!(run) # rubocop:disable Metrics/AbcSize
      say(run.error_list)
      if run.applied_with_failure? && run.sql_script_id
        say("\r\nFile '#{data_root.join(run.summary_hash['sql_rel_path'].to_s)}' saved (Outbox: #{outbox_state(run)}).")
        say(I18n.t('maintenance.rake.partial_apply', file: run.summary_hash['sql_filename']))
      elsif run.applied_with_failure?
        say(I18n.t('maintenance.rake.applied_unregistered', path: run.unregistered_sql_path, folder: run.summary_hash['outbox_folder'] || 'misc'))
      elsif run.script_only?
        say(I18n.t('maintenance.rake.not_written'))
      else
        say("\r\n*** ERROR: Script execution failed. Transaction rolled back. ***")
      end
      stop!(1)
    end

    # (an empty plan writes nothing any more: before phase 13 the tasks wrote a script with no statement)
    def report_refusal!(run, refused)
      reason = run.refusal_reason.to_s
      return stop_with(refused[reason]) if refused.key?(reason)

      say(reason == 'empty' ? I18n.t('maintenance.rake.nothing_to_do') : run.error_list)
      stop!(reason == 'empty' ? nil : 1)
    end

    def stop_with(lines)
      say(*Array(lines))
      stop!(nil)
    end

    def outbox_state(run)
      script = Ops.safely { run.sql_script }
      script ? "#{script.state}, seq #{script.seq}" : 'not registered, ops DB missing'
    end

    # Creates the run (origin 'rake', the operator's acknowledgement given) and runs it inline. Returns the Executor.
    def execute(key, params, mode:, parent: nil, script_name: nil) # rubocop:disable Metrics/AbcSize
      require_ops!
      operation = Maintenance::Registry.fetch(key).new(**params.compact)
      subject_type, subject_id = safe { operation.subject }
      run = Ops::OperationRun.create!(
        operation_key: key, params: operation.to_params, params_digest: operation.params_digest, mode:, parent_run_id: parent&.id,
        status: 'queued', label: safe { operation.label.to_s.truncate(250) }, season_id: safe { operation.season_id },
        subject_type: subject_type&.to_s, subject_id:, origin: 'rake', drift_ack: true
      )
      executor = Executor.new(run:, data_root:, gate: @gate, gate_scope: :rake, gate_force: force?, script_text: SCRIPT_TEXT,
                              script_prefix: env['index'].presence&.to_i, script_name:,
                              sql_runner: PrintingSqlRunner.new(out, @sql_runner),
                              origin: { 'task' => task_name, 'args' => env.to_h.slice(*ORIGIN_ARGS) })
      executor.call
      run.reload
      executor
    end

    def require_ops!
      return if Ops.available?

      say(I18n.t('maintenance.rake.ops_unavailable'))
      stop!(1)
    end

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
