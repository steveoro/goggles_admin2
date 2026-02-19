# frozen_string_literal: true

require 'rails_helper'
require GogglesDb::Engine.root.join('spec', 'support', 'shared_method_existence_examples')

RSpec.describe PdfResults::ContextDef, type: :strategy do
  let(:fixture_name) { "#{FFaker::Lorem.word}-#{(rand * 100).to_i}" }
  let(:valid_bool_props) do
    result = {}
    PdfResults::ContextDef::BOOL_PROPS.each { |p| result[p] = FFaker::Boolean.sample }
    result
  end
  let(:valid_int_props) do
    result = {}
    PdfResults::ContextDef::INT_PROPS.each { |p| result[p] = (rand * 100).to_i }
    result
  end
  let(:valid_string_props) do
    result = {}
    PdfResults::ContextDef::STRING_PROPS[1..].each { |p| result[p] = FFaker::Lorem.word }
    result.merge('name' => fixture_name)
  end
  let(:all_valid_props) { valid_bool_props.merge(valid_int_props).merge(valid_string_props) }
  let(:all_props_with_defaults) { %w[row_span] }
  let(:non_existing_props) do
    result = {}
    FFaker::Lorem.words(5).each do |p|
      result[p] = [FFaker::Boolean.sample, (rand * 100).to_i, FFaker::Lorem.word].sample
    end
    result
  end

  let(:props_1ficr1_results_indexes) do
    {
      name: 'results',
      fields: [
        { name: 'rank',         pop_out: false, format: '\\s?(\\d{1,2}|SQ|RT|NP|ES)' },
        { name: 'swimmer_name', pop_out: false, format: '\\s+(\\w+(\\s\\w+){1,4})\\s+', token_end: 45 },
        { name: 'nation',       pop_out: false, format: '\\s+\\s(\\w{2,3})\\s\\s+' },
        { name: 'birth_year',   pop_out: false, format: '\\s+\\s(\\d{4})\\s\\s+' },
        { name: 'team_name',    pop_out: false, format: '\\s*([\\w\\d]+(\\s[\\w\\d&.-]+)+)\\s\\s+', token_start: 88 },
        { name: 'heat_num',     pop_out: false, format: '\\s*(\\d{1,3})\\s*', token_start: 122 },
        { name: 'lane_num',     pop_out: false, format: '\\s*(\\d{1,2})\\s*', token_start: 127 },
        { name: 'heat_rank',    pop_out: false, format: '\\s*(\\d{1,2}|SQ|RT|NP|ES)\\s*', token_start: 133 },
        { name: 'timing',       pop_out: false, format: "\\s*((?>\\d{1,2}[':\\.])?\\d{1,2}[\":\\.]\\d{1,2})\\s*", token_start: 138 },
        { name: 'team_score',   pop_out: false, format: '\\s*(.+)\\s*', required: false, token_start: 146 },
        { name: 'dsq_type',     pop_out: false, format: '\\s*(.+)\\b', required: false, token_start: 146 },
        { name: 'std_score',    pop_out: false, format: '\\s*(\\d{1,4}[,.]\\d{1,2})\\b', required: false, token_start: 146 }
      ]
    }
  end
  let(:props_1ficr1_results_popout) do
    {
      name: 'results',
      fields: [
        { name: 'rank',         format: '\\s?(\\d{1,2}|SQ|RT|NP|ES)' },
        { name: 'swimmer_name', format: '\\s+(\\w+(\\s\\w+){1,4})\\s+', token_end: 45 },
        { name: 'nation',       format: '\\s+\\s(\\w{2,3})\\s\\s+' },
        { name: 'birth_year',   format: '\\s+\\s(\\d{4})\\s\\s+' },
        { name: 'team_name',    format: '\\s+\\s([\\w\\d]+(\\s[\\w\\d&.-]+)+)\\s\\s+' },
        { name: 'heat_num',     format: '\\s*(\\d{1,3})\\s*' },
        { name: 'lane_num',     format: '\\s*(\\d{1,2})\\s*' },
        { name: 'heat_rank',    format: '\\s*(\\d{1,2}|SQ|RT|NP|ES)\\s*' },
        { name: 'timing',       format: "\\s*((?>\\d{1,2}[':\\.])?\\d{1,2}[\":\\.]\\d{1,2})\\s*" },
        { name: 'team_score',   format: '\\s*(.+)\\s*', required: false },
        { name: 'dsq_type',     format: '\\s*(.+)\\b', required: false },
        { name: 'std_score',    format: '\\s*(\\d{1,4}[,.]\\d{1,2})\\b', required: false }
      ]
    }
  end
  let(:props_1ficr1_category) do
    {
      name: 'category',
      row_span: 2,
      format: '\\s*((\\w+\\s?){1,4})\\b'
    }
  end
  let(:props_1ficr1_results_hdr) do
    {
      name: 'results_hdr',
      lambda: 'strip',
      format: '\\s?Pos.\\s+Nominativo\\s+Naz\\s+Anno\\s+Società\\s+Ser.\\s+Cor\\s+Pos\\s+Tempo\\s+Pti.\\sSC\\s+Master\\b'
    }
  end
  let(:props_1ficr1_event) do
    {
      name: 'event',
      rows: [
        {
          fields: [
            { name: 'event_length', lambda: 'strip', format: '\\s*(\\d{2,4})m?\\s+' },
            { name: 'event_type', lambda: 'strip', format: '\\s*((\\w+\\s?){1,4})\\b' }
          ]
        },
        {
          fields: [
            { name: 'Riepilogo', lambda: 'strip' }
          ]
        }
      ]
    }
  end
  #-- -------------------------------------------------------------------------
  #++

  # === NOTE: ===
  # The following fixture properties were all based on the actual layout format '1-ficr1'
  # (slight differences may exist since the actual format file evolved in time and this spec has not)
  #
  # In any case, DO NOT edit the following to match exactly the source format file and use properties
  # like 'required: false', 'at_fixed_row: N', or 'repeatable: true' as each fixture is tested against
  # a limited number of source buffer lines and are expected to match at offset row #0.
  # ("Repeatables" & "optionals" would make the test fail too.)
  let(:props_1ficr1_header) do
    {
      name: 'header',
      rows: [
        {
          fields: [
            { name: 'edition', lambda: 'strip', format: '\\s*(\\d{1,2}).{1,2}\\s+' },
            { name: 'meeting_name', lambda: 'strip', format: "\\s*[°^*oa']?\\s+(.+)\\b" }
          ]
        },
        {
          fields: [
            { name: 'meeting_place', lambda: 'strip', format: '\\s*(\\w{2,}),\\s+' },
            { name: 'meeting_date', lambda: 'strip', format: '\\s*(\\d{2}[-/]\\d{2}[-/]\\d{2,4})\\b' }
          ]
        }
      ]
    }
  end
  let(:optional_rows) do
    [
      described_class.new(name: FFaker::Lorem.unique.word, required: false),
      described_class.new(name: FFaker::Lorem.unique.word, required: false)
    ]
  end
  let(:required_rows) do
    [
      described_class.new(name: FFaker::Lorem.unique.word),
      described_class.new(name: FFaker::Lorem.unique.word),
      described_class.new(name: FFaker::Lorem.unique.word)
    ]
  end
  let(:optional_fields) do
    [
      PdfResults::FieldDef.new(name: FFaker::Name.unique.name, required: false),
      PdfResults::FieldDef.new(name: FFaker::Name.unique.name, required: false)
    ]
  end
  #-- -------------------------------------------------------------------------
  #++

  let(:required_fields) do
    [
      PdfResults::FieldDef.new(name: FFaker::Name.unique.name),
      PdfResults::FieldDef.new(name: FFaker::Name.unique.name),
      PdfResults::FieldDef.new(name: FFaker::Name.unique.name)
    ]
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
        non_existing_props.each_key { |prop_key| expect(new_instance).not_to respond_to(prop_key) }
      end

      it 'stores only the supplied existing property values' do
        all_valid_props.each { |prop_key, prop_val| expect(new_instance.send(prop_key)).to eq(prop_val) }
      end

      it 'leaves all other supported properties (which were not given as parameters) to nil' do
        PdfResults::ContextDef::ALL_PROPS.reject { |key| all_valid_props.key?(key) || all_props_with_defaults.include?(key) }
                                         .each { |prop_key| expect(new_instance.send(prop_key)).to be_nil }
      end

      it_behaves_like(
        'responding to a list of methods',
        %i[
          last_validation_result curr_index consumed_rows
          data_hash dao
          bool_props all_props optional? required_fields required_rows
          key_attributes_from_fields key_attributes_from_rows key_hash
          key valid? extract to_s
        ]
      )
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe 'properties with default false,' do
    %w[
      repeat eop optional_if_empty
    ].each do |prop_name|
      context "'#{prop_name}' when not specified" do
        it 'defaults to false' do
          expect(described_class.new(name: FFaker::Lorem.word).send(prop_name)).to be false
        end
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
    context 'when not specified' do
      it 'defaults to nil' do
        expect(described_class.new(name: FFaker::Lorem.word).format).to be_nil
      end
    end
  end

  describe '#bool_props' do
    it 'returns the list of supported boolean properties' do
      expect(described_class.new(name: FFaker::Lorem.word).bool_props).to eq(PdfResults::ContextDef::BOOL_PROPS)
    end
  end

  describe '#all_props' do
    it 'returns the list of all supported properties' do
      expect(described_class.new(name: FFaker::Lorem.word).all_props).to eq(PdfResults::ContextDef::ALL_PROPS)
    end
  end

  describe '#optional?' do
    it 'is true when required is false' do
      expect(described_class.new(name: FFaker::Lorem.word, required: false).optional?).to be true
    end
  end

  describe '#dao' do
    it 'is blank by default' do
      expect(described_class.new(name: FFaker::Lorem.word).dao).to be_blank
    end
  end

  describe '#data_hash' do
    it 'is empty by default' do
      expect(described_class.new(name: FFaker::Lorem.word).data_hash).to eq({})
    end
  end

  describe '#row_span' do
    it 'is 1 by default' do
      expect(described_class.new(name: FFaker::Lorem.word).row_span).to eq(1)
    end
  end

  describe '#required_fields' do
    it 'is an empty Array when there are no fields' do
      expect(described_class.new(name: FFaker::Lorem.unique.word).required_fields).to be_an(Array).and be_empty
    end

    it 'is the Array of required fields when some required fields are defined' do
      expect(
        described_class.new(
          name: FFaker::Lorem.unique.word, fields: required_fields + optional_fields
        ).required_fields
      ).to match_array(required_fields)
    end
  end

  describe '#required_rows' do
    it 'is an empty Array when there are no rows' do
      expect(described_class.new(name: FFaker::Lorem.unique.word).required_rows).to be_an(Array).and be_empty
    end

    it 'is the Array of required sub-contexts when some required rows are defined' do
      expect(
        described_class.new(
          name: FFaker::Lorem.unique.word, rows: required_rows + optional_rows
        ).required_rows
      ).to match_array(required_rows)
    end
  end

  describe '#key_attributes_from_fields' do
    it 'is an empty Hash when there are no fields' do
      expect(described_class.new(name: FFaker::Lorem.unique.word).key_attributes_from_fields).to be_an(Hash).and be_empty
    end

    it 'is the Hash of field names & values extracted from all #required_fields (depending on #keys content)' do
      subj_row = described_class.new(name: FFaker::Lorem.unique.word, fields: required_fields + optional_fields)
      expected_hash = {}
      required_fields.each do |fld|
        expected_hash.merge!({ fld.name => fld.value }) if subj_row.keys.blank? || subj_row.key?(fld.name)
      end

      expect(subj_row.key_attributes_from_fields).to eq(expected_hash)
    end
  end

  describe '#key_attributes_from_rows' do
    it 'is an empty Hash when there are no fields' do
      expect(described_class.new(name: FFaker::Lorem.unique.word).key_attributes_from_rows).to be_an(Hash).and be_empty
    end

    it 'is the Hash of field names & values extracted from all #required_fields (depending on #keys content)' do
      subj_row = described_class.new(name: FFaker::Lorem.unique.word, rows: required_rows + optional_rows)
      expected_hash = {}
      required_rows.each do |ctx|
        expected_hash.merge!({ ctx.name => ctx.key }) if subj_row.keys.blank? || subj_row.key?(ctx.name)
      end

      expect(subj_row.key_attributes_from_rows).to eq(expected_hash)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#key' do
    context 'when no #keys names have been defined' do
      subject do
        described_class.new(
          name: FFaker::Lorem.unique.word,
          fields: required_fields + optional_fields
        )
      end

      context 'but valid?()/extract() have not been run yet' do
        it 'is an empty String' do
          expect(subject.key).to eq('')
        end
      end

      context 'and valid?() or extract() have been run but without a match' do
        it 'is an empty String' do
          subject.valid?(FFaker::BaconIpsum.paragraph, 0)
          expect(subject.key).to eq('')
        end
      end

      # Testing just the key composed from the default field values for brevity here:
      context 'and either valid?() or extract() have been run (successfully)' do
        it 'equals the conjoined string values, using the specified separator, with values from #data_hash' do
          # Build a matching test buffer for the default field format (which is, each required field name):
          test_buffer = subject.fields.map(&:name).join(' ')
          subject.valid?(test_buffer, 0)

          separator = %w[| , ; /].sample
          # There should be no difference between the 2 since no key list was specified:
          expect(subject.key(separator:)).to eq(subject.key_hash.values.join(separator))
          expect(subject.key(separator:)).to eq(subject.data_hash.values.join(separator))
        end
      end
    end

    context 'when some #keys names have been defined' do
      subject do
        described_class.new(
          name: FFaker::Lorem.unique.word,
          keys: required_fields.first(2).map(&:name),
          fields: required_fields + optional_fields
        )
      end

      context 'but valid?()/extract() have not been run yet' do
        it 'is an empty String' do
          expect(subject.key).to eq('')
        end
      end

      context 'and valid?() or extract() have been run but without a match' do
        it 'is an empty String' do
          subject.valid?(FFaker::BaconIpsum.paragraph, 0)
          expect(subject.key).to eq('')
        end
      end

      # Testing just the key composed from the default field values for brevity here:
      context 'and either valid?() or extract() have been run (successfully)' do
        it 'equals the conjoined string values from the listed key names (fields or rows), using the specified separator' do
          # Build a matching test buffer for the default field format (which is, each required field name):
          test_buffer = subject.fields.map(&:name).join(' ')
          subject.valid?(test_buffer, 0)

          separator = %w[| , ; /].sample
          expect(subject.key(separator:)).to eq(subject.key_hash.values.join(separator))
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # (Testing just #fields here in combination with #optional_if_empty? as these
  # tests are convoluted enough already)
  describe '#optional_if_empty? defined as true,' do
    context 'when all required fields are matching,' do
      subject do
        described_class.new(
          name: FFaker::Lorem.unique.word,
          optional_if_empty: true,
          fields: required_fields + optional_fields
        )
      end

      describe '#valid?()' do
        it 'is true' do
          test_buffer = subject.fields.map(&:name).join(' ')
          expect(subject.valid?(test_buffer, 0)).to be true
        end
      end
    end

    context 'when only some of the required fields can match,' do
      subject do
        described_class.new(
          name: FFaker::Lorem.unique.word,
          optional_if_empty: true,
          fields: required_fields + optional_fields
        )
      end

      describe '#valid?()' do
        it 'is false' do
          test_buffer = subject.fields.sample.name.center(35)
          expect(subject.valid?(test_buffer, 0)).to be false
        end
      end
    end

    context 'when none of the required fields can match the source buffer is empty,' do
      subject do
        described_class.new(
          name: FFaker::Lorem.unique.word,
          optional_if_empty: true,
          fields: required_fields + optional_fields
        )
      end

      describe '#valid?()' do
        it 'is false' do
          expect(subject.valid?('', 0)).to be true
        end
      end
    end
  end

  [
    {
      src_buffer: [
        '                                17° MEETING “DELLE GIOVANI MARUGHE“',
        '                                          PARMA, 18/01/2021'
      ],
      props: :props_1ficr1_header
    },
    {
      src_buffer: [
        '                                       50m Stile Libero Master Misti',
        '                                                   Riepilogo'
      ],
      props: :props_1ficr1_event
    },
    {
      src_buffer: [
        'Pos. Nominativo                                                     Naz           Anno   Società                         Ser.   Cor   Pos   Tempo   Pti. SC   Master'
      ],
      props: :props_1ficr1_results_hdr
    },
    {
      src_buffer: [
        '                                                   A20 Under Femmine',
        ''
      ],
      props: :props_1ficr1_category
    },

    {
      src_buffer: [
        '1    MAZZANTI VIEN DAL MARE PEPERONA                                ITA          2001   SBILENCA SPORT 3.0 SSD - MILANO   24    4     2    29.05'
      ],
      props: :props_1ficr1_results_popout
    },
    {
      src_buffer: [
        '1    MAZZANTI VIEN DAL MARE PEPERONA                                ITA          2001   SGUERCIA NUOTO 1997 ASD - PARMA   24    4     2    29.05'
      ],
      props: :props_1ficr1_results_indexes
    },

    {
      src_buffer: [
        ' 2    SGRAGNOLOTTI FEDERICA                                          ITA          2000   SCRONDINO SPORTING CLUB           12    7     3    30.77'
      ],
      props: :props_1ficr1_results_popout
    },
    {
      src_buffer: [
        ' 2    SGRAGNOLOTTI FEDERICA                                          ITA          2000   SCRONDINO SPORTING CLUB           12    7     3    30.77'
      ],
      props: :props_1ficr1_results_indexes
    },
    {
      src_buffer: [
        ' 1    MAZZANTI VIEN DAL MARE PEPERONA                                ITA          2001   SGUERCIA NUOTO 1997 ASD - PARMA   24    4     2    29.05',
        ' 2    SGRAGNOLOTTI FEDERICA                                          ITA          2000   SCRONDINO SPORTING CLUB           12    7     3    30.77'
      ],
      props: :props_1ficr1_results_popout
    },
    {
      src_buffer: [
        ' 1    MAZZANTI VIEN DAL MARE PEPERONA                                ITA          2001   SGUERCIA NUOTO 1997 ASD - PARMA   24    4     2    29.05',
        ' 2    SGRAGNOLOTTI FEDERICA                                          ITA          2000   SCRONDINO SPORTING CLUB           12    7     3    30.77'
      ],
      props: :props_1ficr1_results_indexes
    },
    {
      src_buffer: [
        '3     FALASCONI MARIA BEATRICE                                       ITA          1996   ALL ROUND SPORT & WELLNES         21    2     4    30.38             834,10'
      ],
      props: :props_1ficr1_results_popout
    },
    {
      src_buffer: [
        '3     FALASCONI MARIA BEATRICE                                       ITA          1996   ALL ROUND SPORT & WELLNES         21    2     4    30.38             834,10'
      ],
      props: :props_1ficr1_results_indexes
    }
  ].each do |def_hash|
    context "for a buffer of lines satisfying all conditions (#{def_hash[:props]})," do
      let(:obj_instance) do
        described_class.new(send(def_hash[:props]))
      end

      before(:each) do
        expect(def_hash[:src_buffer]).to be_an(Array).and be_present
        expect(obj_instance).to be_a(described_class)
        expect(obj_instance).to respond_to(:name)
      end

      describe '#valid?' do
        it 'is true when the scan is aligned at the proper starting index' do
          # DEBUG
          puts "=> #{obj_instance.name}"
          expect(obj_instance.valid?(def_hash[:src_buffer], 0)).to be true
        end

        # rubocop:disable Performance/CollectionLiteralInLoop
        it 'is true when the scan is correctly set for forward looking among the buffered lines' do
          # Move the source buffer up 2 rows and test it again with a proper offset index:
          expect(obj_instance.valid?(['', ''] + def_hash[:src_buffer], 2)).to be true
          expect(obj_instance.valid?(['    Riepilogo', '    A20 Under Femmine', ''] + def_hash[:src_buffer], 3))
            .to be true
        end
        # rubocop:enable Performance/CollectionLiteralInLoop

        it 'is false with a misaligned start offset' do
          expect(obj_instance.valid?(def_hash[:src_buffer], 5)).to be false
        end
      end
      #-- -----------------------------------------------------------------------
      #++

      describe '#extract' do
        let(:result) { obj_instance.extract(def_hash[:src_buffer], 0) }

        it 'is a ContextDAO' do
          expect(result).to be_a(PdfResults::ContextDAO)
        end

        describe 'the resulting ContextDAO' do
          it 'has the parent\'s #name' do
            expect(result.name).to eq(obj_instance.name)
          end

          it 'has the parent\'s #key' do
            expect(result.key).to eq(obj_instance.key)
          end

          it 'has a non-empty #fields_hash if the parent has a key value' do
            expect(result.fields_hash).to be_present if obj_instance.key.present?
          end
        end
      end
      #-- -----------------------------------------------------------------------
      #++

      describe '#key (after context check with valid? or extract)' do
        before(:each) { obj_instance.valid?(def_hash[:src_buffer], 0) }

        it 'equals the conjoined string values, using the specified separator, with values from #data_hash' do
          separator = %w[| , ; /].sample # rubocop:disable Performance/CollectionLiteralInLoop
          expect(obj_instance.key(separator:)).to eq(obj_instance.data_hash.values.join(separator))
        end
      end

      describe '#name (after context check with valid? or extract)' do
        before(:each) { obj_instance.valid?(def_hash[:src_buffer], 0) }

        it 'returns the context name' do
          expect(obj_instance.name).to be_present
        end
      end
      #-- -----------------------------------------------------------------------
      #++
    end
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
        row_span: 3,
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
      expect(result =~ /required\.+:\strue/i).to be_present
      expect(result =~ /format\.+: /i).to be_present
      expect(result).to include(Regexp.new(obj_instance.format).to_s)
      expect(result =~ /lambda\.+: /i).to be_present
      expect(result).to include(obj_instance.lambda.to_s)
      expect(result =~ /row_span/i).to be_present
      expect(result).to include(obj_instance.row_span.to_s)
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
