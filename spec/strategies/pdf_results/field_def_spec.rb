# frozen_string_literal: true

require 'rails_helper'
require GogglesDb::Engine.root.join('spec', 'support', 'shared_method_existence_examples')

RSpec.describe PdfResults::FieldDef, type: :strategy do
  let(:fixture_name) { "#{FFaker::Lorem.word}-#{(rand * 100).to_i}" }
  let(:valid_bool_props) do
    result = {}
    PdfResults::FieldDef::BOOL_PROPS.each { |p| result[p] = FFaker::Boolean.sample }
    result
  end
  let(:valid_int_props) do
    result = {}
    PdfResults::FieldDef::INT_PROPS.each { |p| result[p] = (rand * 100).to_i }
    result
  end
  let(:valid_string_props) do
    result = {}
    PdfResults::FieldDef::STRING_PROPS[1..].each { |p| result[p] = FFaker::Lorem.word }
    result.merge('name' => fixture_name)
  end
  let(:all_valid_props) { valid_bool_props.merge(valid_int_props).merge(valid_string_props) }
  let(:all_props_with_defaults) { %w[pop_out format] }
  let(:non_existing_props) do
    result = {}
    FFaker::Lorem.words(5).each do |p|
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
        PdfResults::FieldDef::ALL_PROPS.each { |prop_key| expect(new_instance).to respond_to(prop_key) }
      end

      it 'does not add any getter method named after the unsupported properties passed as parameters' do
        non_existing_props.each_key { |prop_key| expect(new_instance).not_to respond_to(prop_key) }
      end

      it 'stores only the supplied existing property values' do
        all_valid_props.each { |prop_key, prop_val| expect(new_instance.send(prop_key)).to eq(prop_val) }
      end

      it 'leaves all other supported properties (which were not given as parameters or do not have defaults) to nil' do
        PdfResults::FieldDef::ALL_PROPS.reject { |key| all_valid_props.key?(key) || all_props_with_defaults.include?(key) }
                                       .each { |prop_key| expect(new_instance.send(prop_key)).to be_nil }
      end

      it_behaves_like(
        'responding to a list of methods',
        %i[
          value curr_buffer bool_props all_props
          key extract to_s
        ]
      )
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#pop_out' do
    context 'when not specified' do
      it 'defaults to true' do
        expect(described_class.new(name: FFaker::Lorem.word).pop_out).to be true
      end
    end
  end

  describe '#required' do
    context 'when not specified' do
      it 'defaults to true' do
        expect(described_class.new(name: FFaker::Lorem.word).required).to be true
      end
    end
  end

  describe '#format' do
    context 'when not specified in the constructor' do
      subject(:subj_no_format) { described_class.new(name: FFaker::Lorem.words(2).join) }

      it 'defaults to a Regexp matching the name of the field' do
        expect(subj_no_format.format).to eq(Regexp.new("\\W*(#{subj_no_format.name})\\W*", Regexp::IGNORECASE))
      end
    end

    context 'when set to any non-empty string' do
      subject(:subj_w_format) { described_class.new(name: FFaker::Lorem.words(2).join, format: fixture_format) }

      let(:fixture_format) { FFaker::Lorem.words(2).join(' ') }

      it 'is a Regexp matching the supplied format' do
        expect(subj_w_format.format).to eq(Regexp.new(fixture_format, Regexp::IGNORECASE))
      end
    end
  end

  describe '#bool_props' do
    it 'returns the list of supported boolean properties' do
      expect(described_class.new(name: FFaker::Lorem.word).bool_props).to eq(PdfResults::FieldDef::BOOL_PROPS)
    end
  end

  describe '#all_props' do
    it 'returns the list of all supported properties' do
      expect(described_class.new(name: FFaker::Lorem.word).all_props).to eq(PdfResults::FieldDef::ALL_PROPS)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

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
      expect(result_buffer).to be_a(String).and be_present
    end

    it 'is the matched string value' do
      expect(obj_instance.value).to eq(expected_value)
    end

    it 'removes the content of the field value from the source buffer' do
      expect(result_buffer.length).to eq(expected_src.length - obj_instance.value.length)
      # (If the value is contained multiple times in the buffer, only the first one will be removed)
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

    it 'leaves the source buffer the same length' do
      expect(result_buffer).to eq(expected_src)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#extract' do
    context 'when not matching' do
      subject(:result_buffer) { obj_instance.extract(source_row) }

      let(:source_row) { "-o- POSSIBLY SOMETHING THAT WON'T MATCH ANY FFAKER WORD -o-" }
      let(:obj_instance) { described_class.new(name: FFaker::Lorem.words(2).join) }
      let(:expected_src) { source_row.dup }

      before(:each) do
        expect(obj_instance).to be_a(described_class)
        expect(source_row).to be_a(String).and be_present
        expect(expected_src).to be_a(String).and eq(source_row)
        expect(result_buffer).to be_a(String).and be_present
      end

      it 'sets #value to nil' do
        expect(obj_instance.value).to be_nil
      end

      it 'sets the current buffer equal to the source string' do
        expect(result_buffer).to eq(expected_src)
      end
    end

    # (Default format)
    context 'when matching the default format (field name)' do
      context 'and #pop_out is true' do
        let(:obj_instance) { described_class.new(name: FFaker::Lorem.words(2).join) }
        let(:expected_value) { obj_instance.name }
        let(:source_row) { "-o- ANYTHING Else #{expected_value} And much more -o-" }
        let(:expected_src) { source_row.dup }

        it_behaves_like('a matching FieldDef with #pop_out true')
      end

      context 'and #pop_out is false' do
        let(:obj_instance) { described_class.new(name: FFaker::Lorem.words(2).join, pop_out: false) }
        let(:expected_value) { obj_instance.name }
        let(:source_row) { "-o- SOMETHING More #{expected_value} And much more -o-" }
        let(:expected_src) { source_row.dup }

        it_behaves_like('a matching FieldDef with #pop_out false')
      end
    end
    # (Default format END) ----------------------------------------------------

    # (Specific format)
    context 'when matching a specific format' do
      let(:expected_value) { "Meeting #{FFaker::Lorem.words(3).join}" }
      let(:source_row) { "          --- 15th #{expected_value}  ---           " }

      context 'and #pop_out is true' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            format: "\\s+\\d{1,2}.{1,2}\\s+(([\\w\\-'`]+\\s?){1,3})\\s+"
          )
        end
        let(:expected_src) { source_row.dup }

        it_behaves_like('a matching FieldDef with #pop_out true')
      end

      context 'and #pop_out is false' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            format: "\\s+\\d{1,2}.{1,2}\\s+(([\\w\\-'`]+\\s?){1,3})\\s+", pop_out: false
          )
        end
        let(:expected_src) { source_row.dup }

        it_behaves_like('a matching FieldDef with #pop_out false')
      end
    end
    # (Specific format END) ---------------------------------------------------

    # (Format + Lambdas)
    context 'when matching a format preceded with multiple lambdas' do
      let(:original_value) { FFaker::Name.name }
      let(:expected_value) { original_value.upcase }
      let(:source_row) do
        " 9    #{original_value}                               ITA          1963   CSI NUOTO OBER FERRARI           3      2     7           46.25              639,35"
      end

      context 'and #pop_out is true' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            lambda: %w[strip upcase],
            format: "^\\d{1,2}?\\s+(([\\w\\-'`]+\\s){2,5})\\s*[a-zA-Z]{3}"
          )
        end
        let(:expected_src) { source_row.dup.strip.upcase }

        it_behaves_like('a matching FieldDef with #pop_out true')
      end

      context 'and #pop_out is false' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            lambda: %w[strip upcase],
            format: "^\\d{1,2}?\\s+(([\\w\\-'`]+\\s){2,5})\\s*[a-zA-Z]{3}", pop_out: false
          )
        end
        let(:expected_src) { source_row.dup.strip.upcase }

        it_behaves_like('a matching FieldDef with #pop_out false')
      end
    end
    # (Format + Lambdas END) ---------------------------------------------------

    # (Format + Lambdas + indexes)
    context 'when matching a format preceded with multiple lambdas and some indexes' do
      let(:original_value) { FFaker::Name.name }
      let(:expected_value) { original_value.upcase }
      let(:source_row) do
        " 9    #{original_value}                               ITA          1963   CSI NUOTO OBER FERRARI           3      2     7           46.25              639,35"
      end

      context 'and #pop_out is true' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            lambda: %w[strip upcase],
            token_start: 3,
            format: "^\\s+(([\\w\\-'`]+\\s){2,5})\\s+"
          )
        end
        # Indexes should NOT affect the resulting piped source buffer (but should be used just to better
        # define format's domain):
        let(:expected_src) { source_row.dup.strip.upcase }

        it_behaves_like('a matching FieldDef with #pop_out true')
      end

      context 'and #pop_out is false' do
        let(:obj_instance) do
          described_class.new(
            name: FFaker::Lorem.word,
            lambda: %w[strip upcase],
            token_start: 3,
            format: "^\\s+(([\\w\\-'`]+\\s){2,5})\\s+", pop_out: false
          )
        end
        # Indexes should NOT affect the resulting piped source buffer (but should be used just to better
        # define format's domain):
        let(:expected_src) { source_row.dup.strip.upcase }

        it_behaves_like('a matching FieldDef with #pop_out false')
      end
    end
    # (Format + Lambdas + indexes END) ----------------------------------------
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#to_s' do
    subject(:result) { obj_instance.to_s }

    let(:original_value) { FFaker::Name.name }
    let(:source_row) do
      " 9    #{original_value}                               ITA          1963   CSI NUOTO OBER FERRARI           3      2     7           46.25              639,35"
    end
    let(:obj_instance) do
      described_class.new(
        name: FFaker::Lorem.word,
        lambda: %w[strip upcase],
        token_start: 3,
        format: "^\\s+(([\\w\\-'`]+\\s){2,5})\\s+"
      )
    end

    before(:each) do
      expect(source_row).to be_a(String).and be_present
      expect(obj_instance).to be_a(described_class)
    end

    it 'is a String' do
      expect(result).to be_a(String).and be_present
    end

    it 'includes all set properties and their value' do
      # DEBUG:
      # puts result
      expect(result =~ /<#{obj_instance.name}>/i).to be_present
      expect(result =~ /format\.+: /i).to be_present
      expect(result).to include(Regexp.new(obj_instance.format).to_s)
      expect(result =~ /lambda\.+: /i).to be_present
      expect(result).to include(obj_instance.lambda.to_s)
      expect(result =~ /token_start/i).to be_present
      expect(result).to include(obj_instance.token_start.to_s)
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
