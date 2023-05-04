# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SqlMaker, type: :strategy do
  describe 'self.new()' do
    context 'with valid parameters,' do
      subject(:new_instance) { described_class.new(row: GogglesDb::Swimmer.new) }

      it 'creates a new instance' do
        expect(new_instance).to be_an(described_class)
      end

      it 'has an empty #sql_log list of logged statements' do
        expect(new_instance.sql_log).to be_an(Array) && be_empty
      end
    end

    context 'with a non-ActiveRecord row,' do
      it 'raises an ArgumentError' do
        expect { described_class.new(row: 'not-a-row') }.to raise_error(ArgumentError)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#report()' do
    subject(:new_instance) { described_class.new(row: fixture_row) }

    let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    context 'when no statements have been logged' do
      it 'returns an empty string' do
        expect(new_instance.report).to be_a(String) && be_empty
      end
    end

    context 'when at least a statement has been logged' do
      before(:each) { new_instance.log_update }

      it 'returns the logged SQL statement as a single string' do
        expect(new_instance.report).to be_a(String) && be_present && include('UPDATE `swimmers`')
        # Checking just a couple of columns here:
        expect(new_instance.report).to include(fixture_row.complete_name) && include(fixture_row.gender_type_id.to_s)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#log_insert()' do
    subject(:new_instance) { described_class.new(row: fixture_row) }

    let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }
    let(:result) { new_instance.log_insert }

    describe 'result' do
      it 'is a string containing an INSERT statement based on the specified row' do
        expect(result).to be_a(String) && include('INSERT INTO `swimmers`')
      end

      it 'has created_at & updated_at values set to NOW()' do
        # We won't check the actual positioning of the columns here
        expect(result).to include('`created_at`, `updated_at`')
        expect(result).to include('NOW(), NOW()')
      end
    end

    it 'adds the returned result string to the internal #sql_log list' do
      expect(new_instance.sql_log).to include(result)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#log_update()' do
    subject(:new_instance) { described_class.new(row: fixture_row) }

    let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }
    let(:result) { new_instance.log_update }

    describe 'result' do
      it 'is a string containing an UPDATE statement based on the specified row' do
        expect(result).to be_a(String) && include('UPDATE `swimmers`')
      end

      it 'does not include the created_at column' do
        expect(result).not_to include('`created_at`')
      end

      it 'has just the updated_at value set to NOW()' do
        expect(result).to include('`updated_at`=NOW()')
      end
    end

    it 'adds the returned result string to the internal #sql_log list' do
      expect(new_instance.sql_log).to include(result)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#log_destroy()' do
    subject(:new_instance) { described_class.new(row: fixture_row) }

    let(:fixture_row) { FactoryBot.create(:team) }
    let(:result) { new_instance.log_destroy }

    describe 'result' do
      it 'is a string containing a DELETE statement based on the specified row' do
        expect(result).to be_a(String) && include('DELETE FROM `teams`')
      end
    end

    it 'adds the returned result string to the internal #sql_log list' do
      expect(new_instance.sql_log).to include(result)
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
