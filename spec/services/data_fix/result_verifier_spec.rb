# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::ResultVerifier do
  subject(:verifier) { described_class.new(source_path:, checker:) }

  # (no perfect match: nothing is auto-fixed)
  let(:checker) { instance_double(Import::Verification::ResultDuplicateChecker, check_individual: { perfect_matches: [] }) }
  let(:source_path) { "/tmp/result-verifier-spec-#{SecureRandom.hex(4)}-lt4.json" }
  let(:ticks) { [] }
  let(:progress) { ->(message, current, total) { ticks << [message, current, total] } }

  before(:each) do
    5.times do |index|
      GogglesDb::DataImportMeetingIndividualResult.create!(import_key: "rv-spec-#{index}", phase_file_path: source_path,
                                                           meeting_program_id: 1, swimmer_id: 1, rank: 1)
    end
  end

  describe '#verify_all!' do
    it 'ticks the progress sink before the first row, every PROGRESS_EVERY rows and after the last one' do
      stub_const("#{described_class}::PROGRESS_EVERY", 2)
      outcome = verifier.verify_all!(progress:, message: 'Checking')
      expect(outcome).to include('checked' => 5, 'verified' => 0)
      expect(ticks).to eq([['Checking', 0, 5], ['Checking', 2, 5], ['Checking', 4, 5], ['Checking', 5, 5]])
    end

    it 'ticks nothing when there is nothing to verify' do
      other = described_class.new(source_path: "#{source_path}.none", checker:)
      expect(other.verify_all!(progress:)).to include('checked' => 0)
      expect(ticks).to be_empty
    end

    it 'uses its default message and works without a sink' do
      verifier.verify_all!(progress:)
      expect(ticks.map(&:first).uniq).to eq([described_class::PROGRESS_MESSAGE])
      expect(verifier.verify_all!).to include('checked' => 5)
    end
  end
end
