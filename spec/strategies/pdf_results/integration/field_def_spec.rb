# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::FieldDef, type: :integration do
  # (Subject is inside)
  # USES:
  # - expected_value  => string value to be extracted (after applying lambdas, if any)
  # - source_row      => original string source row
  # - expected_src    => string source row with all lambdas applied (collated, if split)
  # - obj_instance    => FieldDef instance to be tested
  # - result_buffer   => actual subject of the test (string buffer returned by the #extract method)
  shared_examples_for('a matching FieldDef with #pop_out true') do
    subject(:result_buffer) { obj_instance.extract(source_row) }

    before(:each) do
      expect(expected_value).to be_a(String).and be_present
      expect(source_row).to be_a(String).and be_present
      expect(expected_src).to be_a(String).and be_present
      expect(obj_instance).to be_a(described_class)
      expect(result_buffer).to be_a(String) # this can be also a bunch of spaces
    end

    it 'is the matched string value' do
      expect(obj_instance.value).to eq(expected_value)
    end

    it 'removes the content of the field value from the source buffer' do
      expect(result_buffer.length).to eq(expected_src.length - obj_instance.value.length)
      # (If the value is contained multiple times in the buffer, only th first one will be removed)
    end
  end

  # (Subject is inside)
  # USES:
  # - expected_value  => string value to be extracted (after applying lambdas, if any)
  # - source_row      => original string source row
  # - expected_src    => string source row with all lambdas applied (collated, if split)
  # - obj_instance    => FieldDef instance to be tested
  # - result_buffer   => actual subject of the test (string buffer returned by the #extract method)
  shared_examples_for('a matching FieldDef with #pop_out false') do
    subject(:result_buffer) { obj_instance.extract(source_row) }

    before(:each) do
      expect(expected_value).to be_a(String).and be_present
      expect(source_row).to be_a(String).and be_present
      expect(expected_src).to be_a(String).and be_present
      expect(obj_instance).to be_a(described_class)
      expect(result_buffer).to be_a(String).and be_present
    end

    it 'is the matched string value' do
      expect(obj_instance.value).to eq(expected_value)
    end

    it 'leaves the source buffer as is' do
      expect(result_buffer).to eq(expected_src)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#extract' do
    # (Format + Lambdas + indexes)
    [
      {
        field: 'swimmer_name', format: "^\\s+(([\\w\\-'`]+\\s){2,5})\\s+",
        token_start: 3,
        lambda: %w[strip upcase], expected_val: "SUSANNA O'KIEF SAINT-RONALD"
      },
      {
        field: 'year_of_birth', format: '\\s*(\\d{4})\\s*',
        token_start: 50,
        lambda: 'strip', expected_val: '1963'
      },
      {
        field: 'state', format: '\\s*(\\w{3})\\s*',
        token_start: 47, token_end: 52,
        lambda: %w[strip downcase], expected_val: 'usa'
      },
      {
        field: 'team_name', format: "\\s+(([\\w\\-'`]+\\s){2,5})\\s+",
        token_start: 66,
        lambda: %w[strip upcase], expected_val: 'JAMIRO SUPER-SWIM CLUB 2001'
      },
      {
        field: 'partial_tname', format: "\\s*(([\\w\\d\\-'`]+\\s){2,6})\\s*",
        starts_with: 'JAMIRO', ends_with: '2001',
        lambda: %w[strip upcase], expected_val: 'SUPER-SWIM CLUB'
      }
    ].each do |prop_array|
      context "when matching #{prop_array[:field]} in layout 1-ficr1," do
        let(:expected_value) { prop_array[:expected_val] }
        let(:source_row) do
          " 9    Susanna O'Kief Saint-Ronald               USA          1963   Jamiro Super-Swim Club 2001          3      2     7         46.25            639,35"
        end

        # Compute expected resulting source buffer, depending on current fixture:
        let(:expected_src) do
          (prop_array[:lambda].include?('upcase') && source_row.dup.strip.upcase) ||
            (prop_array[:lambda].include?('downcase') && source_row.dup.strip.downcase) ||
            source_row.dup.strip
        end

        context 'and #pop_out is true' do
          let(:obj_instance) do
            described_class.new(
              name: prop_array[:field],
              token_start: prop_array[:token_start],
              token_end: prop_array[:token_end],
              starts_with: prop_array[:starts_with],
              ends_with: prop_array[:ends_with],
              lambda: prop_array[:lambda],
              format: prop_array[:format]
            )
          end

          it_behaves_like('a matching FieldDef with #pop_out true')
        end

        context 'and #pop_out is false' do
          let(:obj_instance) do
            described_class.new(
              name: prop_array[:field],
              pop_out: false,
              token_start: prop_array[:token_start],
              token_end: prop_array[:token_end],
              starts_with: prop_array[:starts_with],
              ends_with: prop_array[:ends_with],
              lambda: prop_array[:lambda],
              format: prop_array[:format]
            )
          end

          it_behaves_like('a matching FieldDef with #pop_out false')
        end
      end
    end
    # (Format + Lambdas + indexes END) ----------------------------------------
  end
  #-- -------------------------------------------------------------------------
  #++
end
