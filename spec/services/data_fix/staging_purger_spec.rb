# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::StagingPurger do
  let(:source_a) { 'crawler/data/results.new/9999/purger-a-lt4.json' }
  let(:source_b) { 'crawler/data/results.new/9999/purger-b-lt4.json' }
  let(:tables) { described_class::TABLES.values }

  def create_rows_for(path, tag)
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key: "#{tag}-mir", phase_file_path: path, rank: 1)
    GogglesDb::DataImportLap.create!(import_key: "#{tag}-lap", parent_import_key: "#{tag}-mir", phase_file_path: path,
                                     length_in_meters: 50)
    GogglesDb::DataImportMeetingRelayResult.create!(import_key: "#{tag}-mrr", phase_file_path: path, rank: 1)
    GogglesDb::DataImportMeetingRelaySwimmer.create!(import_key: "#{tag}-mrs", parent_import_key: "#{tag}-mrr",
                                                     phase_file_path: path, relay_order: 1)
    GogglesDb::DataImportRelayLap.create!(import_key: "#{tag}-rlap", parent_import_key: "#{tag}-mrr",
                                          phase_file_path: path, length_in_meters: 50)
  end

  before(:each) do
    tables.each(&:delete_all)
    create_rows_for(source_a, 'purger-a')
    create_rows_for(source_b, 'purger-b')
  end

  after(:each) { tables.each(&:delete_all) }

  describe '.purge!' do
    it 'deletes only the rows of the given source, in all five tables' do
      deleted = described_class.purge!(source_a)

      expect(deleted.values.sum).to eq(5)
      tables.each do |table|
        expect(table.where(phase_file_path: source_a)).to be_none
        expect(table.where(phase_file_path: source_b).count).to eq(1)
      end
    end

    it 'records one scoped datafix.purged event' do
      expect { described_class.purge!(source_a) }.to change(Ops::Event, :count).by(1)

      event = Ops::Event.of_kind('datafix.purged').recent.first
      expect(event.subject_key).to eq(source_a)
      expect(event.data['scope']).to eq(source_a)
    end

    it 'still purges when the ops write fails' do
      allow(Ops).to receive(:record_event!).and_raise(StandardError, 'ops down')

      expect { described_class.purge!(source_a) }.not_to raise_error
      expect(GogglesDb::DataImportLap.where(phase_file_path: source_a)).to be_none
    end
  end

  describe '.purge_all!' do
    it 'clears all five tables and records a scope "all" event' do
      expect { described_class.purge_all! }.to change(Ops::Event, :count).by(1)

      tables.each { |table| expect(table.count).to eq(0) }
      expect(Ops::Event.of_kind('datafix.purged').recent.first.data['scope']).to eq('all')
    end
  end

  describe '.known_source?' do
    it 'is true only for a source having staging rows' do
      expect(described_class.known_source?(source_a)).to be true
      expect(described_class.known_source?('crawler/data/nope.json')).to be false
      expect(described_class.known_source?('')).to be false
    end
  end
end
