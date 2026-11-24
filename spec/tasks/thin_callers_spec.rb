# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# Phase 13: the operational rake tasks are thin callers of the maintenance operations (Maintenance::RakeRunner).
RSpec.describe 'operational rake tasks: thin callers' do # rubocop:disable RSpec/DescribeClass
  let(:thin_files) do
    %w[merge fix purge recompute normalize import_categories import_standard_timings].map { |name| Rails.root.join("lib/tasks/#{name}.rake") }
  end

  before(:each) { Rails.application.load_tasks unless Rake::Task.task_defined?('merge:swimmer') }

  it 'never calls a strategy, the Outbox writer or the local SQL runner, and defines no helper of its own' do
    thin_files.each do |file|
      code = file.read.lines.grep_v(/\A\s*#/).join
      expect(code).not_to match(/\b(?:Merge|Fix|Purge|Recompute|Normalize|Import|SeasonBoard)::\w+\.new\b/), file.basename.to_s
      expect(code).not_to match(/\bdef\s+\w+/), file.basename.to_s
      expect(code).not_to match(/process_sql_file|Outbox::Writer|LocalDb::SqlRunner|execute_sql_file/), file.basename.to_s
    end
  end

  it 'routes every converted task through Maintenance::RakeRunner with its own name' do
    sources = (thin_files + %w[check season_board].map { |name| Rails.root.join("lib/tasks/#{name}.rake") }).map(&:read).join
    Maintenance::RakeTasks.task_names.each do |task_name|
      expect(Rake::Task.task_defined?(task_name)).to be(true), task_name
      expect(sources).to include("Maintenance::RakeRunner.call('#{task_name}'"), task_name
    end
  end

  it 'has no hard-coded DEFAULT_SEASON_ID left' do
    expect(Rails.root.glob('lib/tasks/*.rake').select { |file| file.read.include?('DEFAULT_SEASON_ID') }).to be_empty
  end
end
