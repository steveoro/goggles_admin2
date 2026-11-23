# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The rake SQL producers (merge, fix, purge, recompute, check, normalize, import_categories: all through
# #process_sql_file) and 'db:run' (#execute_sql_file) feed the SQL Outbox. Never writes under the real
# crawler/data (SCRIPT_OUTPUT_DIR is stubbed) and never runs SQL (Open3.capture3 is stubbed).
RSpec.describe 'Outbox rake producers' do # rubocop:disable RSpec/DescribeClass
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:sql_log) { ['-- merge', 'START TRANSACTION;', 'UPDATE swimmers SET x=1 WHERE id=2;', 'COMMIT;'] }
  let(:ok_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:ko_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }
  let(:runner) { Object.new }

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('merge:swimmer')
    stub_const('SCRIPT_OUTPUT_DIR', data_root.join('results.new'))
    write_sql_file(data_root, 'results.sent/262/0476-a-lt4.sql')
  end

  after(:each) do
    FileUtils.rm_rf(data_root)
    ENV.delete('index')
  end

  def process(**options)
    runner.send(:process_sql_file, file_name: '0477-merge_swimmers-1-2', sql_log_array: sql_log, **options)
  end

  describe 'process_sql_file' do
    it 'writes the same bytes as before, in results.new/misc with the next global seq, held when simulated' do
      script = nil
      expect { script = process }.to output(/NOTHING WAS DONE TO THE DB/).to_stdout
      expect(script.absolute_path).to eq(data_root.join('results.new/misc/0477-merge_swimmers-1-2.sql'))
      expect(File.binread(script.absolute_path)).to eq("#{sql_log.join("\r\n")}\n")
      expect(script).to have_attributes(kind: 'merge', folder: 'misc', state: 'held', held_reason: 'not_applied_locally',
                                        applied_locally: false)
    end

    it 'routes a season subdir to the season folder and any other name to misc' do
      expect { expect(process(subdir: 262).folder).to eq('262') }.to output.to_stdout
      expect { expect(process(subdir: 'normalize').folder).to eq('misc') }.to output.to_stdout
    end

    it 'keeps an explicit index as the file prefix only' do
      ENV['index'] = '12'
      script = nil
      expect { script = runner.send(:process_sql_file, file_name: '0012-purge_meeting-9', sql_log_array: sql_log) }.to output.to_stdout
      expect(script).to have_attributes(filename: '0012-purge_meeting-9.sql', seq: 477, kind: 'purge')
    end

    it 'applies the script locally with simulate=0, then makes it pushable' do
      allow(Open3).to receive(:capture3).and_return(['', '', ok_status])
      script = nil
      expect { script = process(simulate: false) }.to output(/Outbox: pending/).to_stdout
      expect(script.reload).to have_attributes(state: 'pending', applied_locally: true, held_reason: nil)
      expect(Open3).to have_received(:capture3).once
    end

    it 'holds the script and exits non-zero when the local apply fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'ERROR 1146', ko_status])
      expect { process(simulate: false) }.to raise_error(SystemExit).and output(/Script execution failed/).to_stdout
      expect(Ops::SqlScript.last).to have_attributes(state: 'held', held_reason: 'local_apply_failed', last_error: 'ERROR 1146')
    end
  end

  it 'auto_index_from_script_output_dir continues the global sequence' do
    expect(runner.send(:auto_index_from_script_output_dir, 999)).to eq(477)
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
