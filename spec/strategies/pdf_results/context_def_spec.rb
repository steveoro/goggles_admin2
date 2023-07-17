# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::ContextDef, type: :strategy do
  let(:fixture_name) { "#{FFaker::Lorem.word}-#{(rand * 100).to_i}" }
  let(:valid_bool_props) do
    result = {}
    PdfResults::ContextDef::BOOL_PROPS.sample(3).each { |p| result[p] = FFaker::Boolean.sample }
    result
  end
  let(:valid_int_props) do
    result = {}
    PdfResults::ContextDef::INT_PROPS.sample(3).each { |p| result[p] = (rand * 100).to_i }
    result
  end
  let(:valid_string_props) do
    result = {}
    PdfResults::ContextDef::STRING_PROPS.sample(3).each { |p| result[p] = FFaker::Lorem.word }
    result.merge('name' => fixture_name)
  end
  let(:all_valid_props) { valid_bool_props.merge(valid_int_props).merge(valid_string_props) }
  let(:non_existing_props) do
    result = {}
    FFaker::Lorem.word.sample(5).each do |p|
      result[p] = [FFaker::Boolean.sample, (rand * 100).to_i, FFaker::Lorem.word].sample
    end
    result
  end

  describe 'a new instance,' do
    context 'when given a mix of existing & non-existing properties,' do
      subject(:new_instance) { described_class.new(all_valid_props.merge(non_existing_props)) }

      it 'creates a new instance in any case' do
        expect(new_instance).to be_a(described_class)
      end

      it 'has a getter method for each one of the existing supported properties' do
        PdfResults::ContextDef::ALL_PROPS.each { |prop_key| expect(new_instance).to respond_to(prop_key) }
      end

      it 'does not add any getter method named after the unsupported properties passed as parameters' do
        non_existing_props.keys.each { |prop_key| expect(new_instance).not_to respond_to(prop_key) }
      end

      it 'stores only the supplied existing property values' do
        all_valid_props.each { |prop_key, prop_val| expect(new_instance.send(prop_key)).to eq(prop_val) }
      end

      it 'leaves all other supported properties (which were not given as parameters) to nil' do
        PdfResults::ContextDef::ALL_PROPS.reject { |key| all_valid_props.keys.include?(key) }
                                         .each { |prop_key| expect(new_instance.send(prop_key)).to be nil }
      end
    end

    context 'when given a fixture YAML section as properties,' do
      # TODO
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#field_properties_at' do
    # TODO
    # subject(:new_instance) { described_class.new(row: fixture_row) }

    # let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    # context 'when no statements have been logged' do
    #   it 'returns an empty string' do
    #     expect(new_instance.report).to be_a(String) && be_empty
    #   end
    # end
  end

  describe '#all_field_properties' do
    # TODO
    # subject(:new_instance) { described_class.new(row: fixture_row) }

    # let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    # context 'when no statements have been logged' do
    #   it 'returns an empty string' do
    #     expect(new_instance.report).to be_a(String) && be_empty
    #   end
    # end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#applicable?' do
    # TODO
    # subject(:new_instance) { described_class.new(row: fixture_row) }

    # let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    # context 'when no statements have been logged' do
    #   it 'returns an empty string' do
    #     expect(new_instance.report).to be_a(String) && be_empty
    #   end
    # end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#valid?' do
    # TODO
    # subject(:new_instance) { described_class.new(row: fixture_row) }

    # let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    # context 'when no statements have been logged' do
    #   it 'returns an empty string' do
    #     expect(new_instance.report).to be_a(String) && be_empty
    #   end
    # end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#extract' do
    # TODO
    # subject(:new_instance) { described_class.new(row: fixture_row) }

    # let(:fixture_row) { GogglesDb::Swimmer.first(100).sample }

    # context 'when no statements have been logged' do
    #   it 'returns an empty string' do
    #     expect(new_instance.report).to be_a(String) && be_empty
    #   end
    # end
  end
  #-- -------------------------------------------------------------------------
  #++
end
