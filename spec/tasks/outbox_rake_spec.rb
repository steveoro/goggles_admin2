# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The rake SQL producers feed the SQL Outbox: since phase 13 the operational tasks (merge, fix, purge, recompute, check,
# normalize, import) register their scripts through Maintenance::RakeRunner / Maintenance::Executor (the former
# #process_sql_file is gone); 'db:run' still uses #execute_sql_file. Never writes under the real crawler/data
# (SCRIPT_OUTPUT_DIR is stubbed) and never runs SQL (Open3.capture3 is stubbed).
RSpec.describe 'Outbox rake producers' do # rubocop:disable RSpec/DescribeClass
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:ok_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:ko_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }
  let(:task) { Rake::Task['normalize:coded_names'] }

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('merge:swimmer')
    stub_const('SCRIPT_OUTPUT_DIR', data_root.join('results.new'))
    write_sql_file(data_root, 'results.sent/262/0476-a-lt4.sql')
    GogglesDb::Meeting.where(id: 1).update_all(code: 'parity-not-normalized') # rubocop:disable Rails/SkipsModelValidations
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  after(:each) do
    FileUtils.rm_rf(data_root)
    %w[index limit simulate].each { |key| ENV.delete(key) }
  end

  def invoke(**env)
    ENV['limit'] = '2'
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    task.reenable
    Rake::Task['merge:check_needed_dirs'].reenable
    task.invoke
  end

  def script = Ops::SqlScript.find_by(kind: 'normalize')

  describe 'rake scripts (Maintenance::RakeRunner)' do
    it 'writes the same bytes as before, in results.new/misc with the next global seq, held when simulated' do
      expected = Normalize::CodedNames.new(limit: 2).call.single_transaction_sql_log
      expect { invoke }.to output(/NOTHING WAS DONE TO THE DB/).to_stdout
      expect(script).to have_attributes(rel_path: 'results.new/misc/0477-normalize_coded_names.sql', folder: 'misc', state: 'held',
                                        held_reason: 'not_applied_locally', applied_locally: false)
      expect(File.binread(data_root.join(script.rel_path))).to eq("#{expected.join("\r\n")}\n")
    end

    it 'keeps an explicit index as the file prefix only' do
      expect { invoke(index: 12) }.to output.to_stdout
      expect(script).to have_attributes(filename: '0012-normalize_coded_names.sql', seq: 477)
    end

    it 'applies the script locally with simulate=0, then registers it pushable' do
      allow(Open3).to receive(:capture3).and_return(['', '', ok_status])
      expect { invoke(simulate: 0) }.to output(/--> Executing script\.\.\..*Outbox: pending/m).to_stdout
      expect(script).to have_attributes(state: 'pending', applied_locally: true, held_reason: nil)
      expect(Open3).to have_received(:capture3).once
    end

    it 'registers nothing and exits non-zero when the local apply fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'ERROR 1146', ko_status])
      expect { invoke(simulate: 0) }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
                                    .and output(/ERROR 1146.*Script execution failed/m).to_stdout
      expect(script).to be_nil
      expect(Dir.glob(data_root.join('results.new/**/*.sql').to_s)).to be_empty
    end
  end

  describe 'db:run' do
    it 'marks a held script as applied locally' do
      script = Outbox::Writer.write!(kind: 'merge', name: 'merge_teams-1-2', sql: "SELECT 1;\n", folder: 'misc',
                                     applied_locally: false, data_root:)
      allow(Open3).to receive(:capture3).and_return(['', '', ok_status])
      ENV['path'] = script.absolute_path.to_s
      Rake::Task['db:run'].reenable
      expect { Rake::Task['db:run'].invoke }.to output(/Done/).to_stdout
      expect(script.reload).to have_attributes(state: 'pending', applied_locally: true)
    ensure
      ENV.delete('path')
    end
  end
end
