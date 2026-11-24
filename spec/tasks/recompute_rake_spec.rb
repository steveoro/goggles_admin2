# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# 'recompute:ranks' after the Recompute::Ranks extraction (phase 11): same console text and same SQL as the code it
# replaced (baseline recorded on goggles_test before the change, meeting and season runs: identical bytes, only the
# folder and the file prefix differ). SCRIPT_OUTPUT_DIR is a temp dir; nothing is run on the DB (simulate).
RSpec.describe 'recompute:ranks' do # rubocop:disable RSpec/DescribeClass
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:task) { Rake::Task['recompute:ranks'] }
  let(:meeting) { FactoryBot.create(:meeting) }

  before(:each) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('recompute:ranks')
    stub_const('SCRIPT_OUTPUT_DIR', data_root.join('results.new'))
    task.reenable
    Rake::Task['merge:check_needed_dirs'].reenable
  end

  after(:each) do
    FileUtils.rm_rf(data_root)
    %w[meeting season simulate index].each { |key| ENV.delete(key) }
  end

  it 'prints the same progress lines and writes the Recompute::Ranks SQL (held, simulate)' do
    program = health_individual_program(meeting)
    FactoryBot.create(:meeting_individual_result, meeting_program: program, minutes: 0, seconds: 40, hundredths: 0, rank: 1)
    FactoryBot.create(:meeting_individual_result, meeting_program: program, minutes: 0, seconds: 30, hundredths: 0, rank: 2)
    ENV['meeting'] = meeting.id.to_s
    expected_sql = Recompute::Ranks.new(meeting: GogglesDb::Meeting.find(meeting.id)).call.sql_log
    output = capture_stdout_of { task.invoke }

    description = "Meeting 1/1, ID #{meeting.id} '#{meeting.description}', MIRs: 2, MRRs: 0"
    expect(output).to include("*** Task: recompute:ranks - season  ***\n", "\r\n- SIMULATE...............: ✔\n",
                              "- 1 meetings found.\n\n", "- #{description}:\n.\n", "\r\nGenerating file '",
                              '>>> NOTHING WAS DONE TO THE DB', "Done.\n")
    file = Dir.glob(data_root.join('results.new/misc/*-recompute_ranks.sql').to_s).sole
    expect(File.basename(file)).to match(/\A\d{4}-#{meeting.season_id}-recompute_ranks\.sql\z/)
    expect(File.binread(file)).to eq("#{expected_sql.join("\r\n")}\n")
    expect(expected_sql.grep(/\AUPDATE/).size).to eq(2)
  end

  def capture_stdout_of
    buffer = StringIO.new
    original = $stdout
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end
end
