# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'

RSpec.describe Import::PhaseCommitLogger do
  let(:temp_file) { Tempfile.new(['test_log', '.log']) }
  let(:log_path) { temp_file.path }
  let(:logger) { described_class.new(log_path: log_path) }

  after(:each) { temp_file.unlink }

  describe '#log_success' do
    it 'records successful entity commits' do
      logger.log_success(entity_type: 'Meeting', entity_id: 123, action: 'created')

      expect(logger.entries.size).to eq(1)
      entry = logger.entries.first
      expect(entry[:level]).to eq(:info)
      expect(entry[:entity_type]).to eq('Meeting')
      expect(entry[:entity_id]).to eq(123)
      expect(entry[:action]).to eq('created')
    end
  end

  describe '#log_validation_error' do
    it 'records validation errors with model details' do
      team = FactoryBot.build(:team, name: nil) # Invalid

      logger.log_validation_error(
        entity_type: 'Team',
        entity_key: 'team-key-123',
        model_row: team
      )

      expect(logger.entries.size).to eq(1)
      entry = logger.entries.first
      expect(entry[:level]).to eq(:error)
      expect(entry[:entity_type]).to eq('Team')
      expect(entry[:entity_key]).to eq('team-key-123')
      expect(entry[:error]).to include('name')
    end

    it 'handles simple error messages' do
      logger.log_validation_error(
        entity_type: 'Badge',
        entity_id: 456,
        error: StandardError.new('Test error')
      )

      expect(logger.entries.size).to eq(1)
      expect(logger.entries.first[:error]).to eq('Test error')
    end
  end

  describe '#log_error' do
    it 'records general errors' do
      logger.log_error(
        message: 'File not found',
        entity_type: 'Phase1',
        entity_key: 'phase1-file'
      )

      expect(logger.entries.size).to eq(1)
      entry = logger.entries.first
      expect(entry[:level]).to eq(:error)
      expect(entry[:message]).to eq('File not found')
    end
  end

  describe '#write_log_file' do
    let(:stats) do
      {
        meetings_created: 1,
        teams_created: 5,
        swimmers_created: 10,
        badges_created: 20,
        errors: ['Error 1', 'Error 2']
      }
    end

    it 'writes formatted log file with stats and entries' do
      logger.log_success(entity_type: 'Meeting', entity_id: 1, action: 'created')
      logger.log_error(message: 'Test error', entity_type: 'Badge')

      logger.write_log_file(stats: stats)

      content = File.read(log_path)
      expect(content).to include('Phase 6 Commit Log')
      expect(content).to include('STATISTICS')
      expect(content).to include('meetings_created: 1')
      expect(content).to include('teams_created: 5')
      expect(content).to include('ERRORS SUMMARY (2)')
      expect(content).to include('Error 1')
      expect(content).to include('DETAILED LOG')
      # Log format: [HH:MM:SS] action entity_type, ID: id
      expect(content).to include('created Meeting')
      expect(content).to include('ID: 1')
      expect(content).to include('ERROR: Badge')
    end

    it 'handles logs with no errors' do
      stats_no_errors = stats.merge(errors: [])
      logger.log_success(entity_type: 'Meeting', entity_id: 1, action: 'created')

      logger.write_log_file(stats: stats_no_errors)

      content = File.read(log_path)
      expect(content).to include('STATISTICS')
      expect(content).not_to include('ERRORS SUMMARY')
    end
  end
end
