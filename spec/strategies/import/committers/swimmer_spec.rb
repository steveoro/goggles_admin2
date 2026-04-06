# frozen_string_literal: true

require 'rails_helper'
require 'securerandom'

RSpec.describe Import::Committers::Swimmer do
  let(:stats) do
    {
      swimmers_created: 0,
      swimmers_updated: 0,
      errors: []
    }
  end
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/test.log') }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats: stats, logger: logger, sql_log: sql_log) }

  describe '#commit' do
    context 'with mixed-case names on create' do
      let(:token) { SecureRandom.hex(2) }
      let(:mixed_last_name) { "de roSa#{token}" }
      let(:mixed_first_name) { "mArio#{token}" }
      let(:mixed_complete_name) { "#{mixed_last_name} #{mixed_first_name}" }
      let(:expected_last_name) { mixed_last_name.mb_chars.upcase.to_s }
      let(:expected_first_name) { mixed_first_name.mb_chars.upcase.to_s }
      let(:expected_complete_name) { mixed_complete_name.mb_chars.upcase.to_s }
      let(:swimmer_attrs) do
        {
          'key' => "M|#{mixed_last_name}|#{mixed_first_name}|1980",
          'last_name' => mixed_last_name,
          'first_name' => mixed_first_name,
          'complete_name' => mixed_complete_name,
          'year_of_birth' => 1980,
          'gender_type_id' => GogglesDb::GenderType.find_by(code: 'M')&.id || GogglesDb::GenderType.first&.id
        }
      end

      it 'stores uppercase swimmer names and logs uppercase SQL INSERT values' do
        new_id = committer.commit(swimmer_attrs)
        created = GogglesDb::Swimmer.find(new_id)

        expect(created.last_name).to eq(expected_last_name)
        expect(created.first_name).to eq(expected_first_name)
        expect(created.complete_name).to eq(expected_complete_name)
        expect(stats[:swimmers_created]).to eq(1)
        expect(stats[:errors]).to be_empty
        expect(sql_log.last).to include("'#{expected_last_name}'")
        expect(sql_log.last).to include("'#{expected_first_name}'")
        expect(sql_log.last).to include("'#{expected_complete_name}'")
      ensure
        GogglesDb::Swimmer.find_by(id: new_id)&.destroy
      end
    end

    context 'with mixed-case names on update' do
      let(:existing_swimmer) { FactoryBot.create(:swimmer) }
      let(:mixed_last_name) { 'de roSa' }
      let(:mixed_first_name) { 'mArio' }
      let(:mixed_complete_name) { "#{mixed_last_name} #{mixed_first_name}" }
      let(:expected_last_name) { mixed_last_name.mb_chars.upcase.to_s }
      let(:expected_first_name) { mixed_first_name.mb_chars.upcase.to_s }
      let(:expected_complete_name) { mixed_complete_name.mb_chars.upcase.to_s }
      let(:swimmer_attrs) do
        {
          'key' => "M|#{mixed_last_name}|#{mixed_first_name}|#{existing_swimmer.year_of_birth}",
          'swimmer_id' => existing_swimmer.id,
          'last_name' => mixed_last_name,
          'first_name' => mixed_first_name,
          'complete_name' => mixed_complete_name,
          'year_of_birth' => existing_swimmer.year_of_birth,
          'gender_type_id' => existing_swimmer.gender_type_id
        }
      end

      before(:each) do
        existing_swimmer.update_columns( # rubocop:disable Rails/SkipsModelValidations
          last_name: mixed_last_name,
          first_name: mixed_first_name,
          complete_name: mixed_complete_name,
          updated_at: Time.current
        )
      end

      it 'stores uppercase swimmer names and logs uppercase SQL UPDATE values' do # rubocop:disable RSpec/MultipleExpectations
        result = committer.commit(swimmer_attrs)

        expect(result).to eq(existing_swimmer.id)
        expect(existing_swimmer.reload.last_name).to eq(expected_last_name)
        expect(existing_swimmer.first_name).to eq(expected_first_name)
        expect(existing_swimmer.complete_name).to eq(expected_complete_name)
        expect(stats[:swimmers_updated]).to eq(1)
        expect(stats[:errors]).to be_empty
        expect(sql_log.last).to include("'#{expected_last_name}'")
        expect(sql_log.last).to include("'#{expected_first_name}'")
        expect(sql_log.last).to include("'#{expected_complete_name}'")
      ensure
        existing_swimmer.destroy
      end
    end
  end
end
