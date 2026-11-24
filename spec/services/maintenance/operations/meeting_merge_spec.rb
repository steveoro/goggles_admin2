# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Operations::MeetingMerge do
  let(:source) { GogglesDb::Meeting.find(1) }
  let(:dest) { GogglesDb::Meeting.find(5) }

  it "plans exactly the strategy's SQL without writing, quiet (console_output: false), with the expected counts" do
    merger = Merge::Meeting.new(source:, dest:, skip_columns: false, console_output: false)
    expect { merger.prepare }.not_to output.to_stdout
    operation = described_class.new(source_id: source.id, dest_id: dest.id)
    plan = nil
    expect(primary_db_statements { plan = operation.plan }.grep(HealthSpecHelpers::WRITE_SQL_REGEXP)).to be_empty
    expect(plan.sql_lines).to eq(merger.sql_log)
    expect(operation.captured_output).to be_empty
    expect(plan.console).to eq(merger.log.join("\r\n"))
    expect(plan.summary['expected_counts']).to eq(merger.expected_counts.transform_keys(&:to_s))
    expect(plan.summary['warning_log']).to eq(merger.warning_log.size)
  end

  it 'asks for the typed confirmation and writes merge_meetings-<src>-<dest>' do
    operation = described_class.new(source_id: source.id, dest_id: dest.id)
    plan = operation.plan
    expect(operation.file_base).to eq('merge_meetings-1-5')
    expect(operation.confirmation_for(plan)).to eq(:typed)
    expect(operation.typed_token).to eq('MERGE 1 INTO 5')
  end

  it 'prints the checker progress only with the rake-only console_output param (never on the form)' do
    expect(described_class.form_fields.map(&:name)).to eq(%i[source_id dest_id skip_columns])
    operation = described_class.new(source_id: source.id, dest_id: dest.id, console_output: true)
    operation.plan
    expect(operation.captured_output).to include('Mapping sessions, events and programs...')
  end

  it 'appends the post-merge verification to the console after a local apply' do
    operation = described_class.new(source_id: source.id, dest_id: dest.id)
    plan = operation.plan
    allow(operation.merger).to receive(:verify_merge_result) { $stdout.puts('=> MERGE SUCCESSFUL! ✅') }
    text, console = Maintenance::OutputCapture.capture { operation.after_local_apply(plan) }
    expect(text).to be_nil
    expect(console).to include('MERGE SUCCESSFUL')
  end

  it 'gives errors without raising for invalid params' do
    expect(described_class.new(source_id: 1, dest_id: 1).plan.errors.join).to include(I18n.t('maintenance.errors.same_ids'))
    expect(described_class.new(source_id: 0, dest_id: 5).plan.errors).to eq([I18n.t('maintenance.errors.not_found', what: 'Meeting', id: 0)])
  end
end
