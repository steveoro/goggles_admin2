# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Helpers for the DataFix::Pipeline specs (phase 09): sources built from spec/fixtures/data_fix/pipeline/<name>.json
# in a temporary '<tmp>/242/' folder (never under crawler/data).
module DataFixPipelineHelpers
  PIPELINE_FIXTURES = Rails.root.join('spec/fixtures/data_fix/pipeline')

  # Writes '<dir>/242/<name>-lt4.json' (a result-bearing LT4 source) plus its phase 1-3 files from the fixture, stamped
  # as built by the pipeline (unless +stamped+ is false: pre-existing, adopted files). Returns the DataFix::Pipeline.
  def pipeline_from_fixture(name, dir:, stamped: true)
    season_dir = File.join(dir, '242').tap { |path| FileUtils.mkdir_p(path) }
    source = File.join(season_dir, "#{name}-lt4.json")
    File.write(source, JSON.pretty_generate('layoutType' => 4, 'meetingName' => 'Trofeo Fixture Pipeline', 'dates' => '2025-03-08',
                                            'events' => [{ 'eventCode' => '50SL', 'relay' => false, 'results' => [{ 'category' => 'M45' }] }]))
    fixture = JSON.parse(PIPELINE_FIXTURES.join("#{name}.json").read)
    (1..3).each do |phase|
      PhaseFileManager.new(source.sub('.json', "-phase#{phase}.json")).write!(data: fixture["phase#{phase}"], meta: { 'generator' => 'spec' })
    end
    pipeline = DataFix::Pipeline.for(source, progress: Import::Progress::Null.new, actor: :auto)
    (1..3).each { |phase| pipeline.send(:stamp_built!, phase) } if stamped
    pipeline.reload!
  end

  # Phase 1 structure considered valid (no season / pool rows needed by the review-rule fixtures).
  def stub_valid_structure
    allow(Import::StructureValidator).to receive(:new)
      .and_return(instance_double(Import::StructureValidator, valid?: true, error_messages: []))
  end
end

RSpec.configure do |config|
  config.include(DataFixPipelineHelpers)
end
