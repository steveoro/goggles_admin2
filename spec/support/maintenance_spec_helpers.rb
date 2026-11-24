# frozen_string_literal: true

# Helpers for the maintenance operations specs (spec/services/maintenance, spec/jobs/maintenance,
# spec/requests/maintenance).
module MaintenanceSpecHelpers
  # A Drift::Gate::Result of the given level (:ok, :warn, :block).
  def maintenance_gate_result(level, acknowledged: false)
    Drift::Gate::Result.new(scope: :operation, level:, verdict: nil, reasons: level == :ok ? [] : [{ code: 'stale' }],
                            acknowledged:, forced: false)
  end

  # A stand-in for Drift::Gate answering +level+ (the acknowledgement is passed through).
  def maintenance_gate(level)
    gate = class_double(Drift::Gate)
    allow(gate).to receive(:check) { |scope:, acknowledged: false, **| maintenance_gate_result(level, acknowledged:).with(scope:) }
    gate
  end

  # A stand-in for LocalDb::SqlRunner (success or failure); records the paths it was given and their contents.
  def maintenance_sql_runner(success: true, stderr: '')
    runner = class_double(LocalDb::SqlRunner)
    @maintenance_sql_runs = []
    allow(runner).to receive(:call) do |path:|
      @maintenance_sql_runs << [path.to_s, File.binread(path)]
      LocalDb::SqlRunner::Result.new(success:, stdout: '', stderr:, duration: 0.01, exit_code: success ? 0 : 1)
    end
    runner
  end

  def maintenance_sql_runs = @maintenance_sql_runs || []

  # A stand-in for LocalDb::SqlRunner running the script statements through ActiveRecord, inside the spec transaction
  # (never the MariaDB client: a client run would commit on the shared test DB). Transaction control and SET lines
  # are skipped; statements may span several lines.
  def maintenance_inline_sql_runner
    runner = class_double(LocalDb::SqlRunner)
    allow(runner).to receive(:call) do |path:|
      maintenance_statements(File.binread(path)).each { |sql| ActiveRecord::Base.connection.execute(sql) }
      LocalDb::SqlRunner::Result.new(success: true, stdout: '', stderr: '', duration: 0.01, exit_code: 0)
    end
    runner
  end

  # The data statements of an SQL script text.
  def maintenance_statements(text)
    lines = text.split(/\r?\n/).map(&:strip).reject { |line| line.empty? || line.start_with?('--') }
    lines.join("\n").split(/;\s*(?:--[^\n]*)?(?:\n|\z)/).map(&:strip).reject do |sql|
      sql.empty? || sql.match?(/\A(?:SET|START TRANSACTION|COMMIT)\b/i)
    end
  end
end

RSpec.configure do |config|
  config.include(MaintenanceSpecHelpers)
end
