# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Layout/HeredocIndentation, Layout/IndentationWidth, RSpec/SpecFilePathFormat
RSpec.describe PdfResults::ContextDef, type: :integration do # rubocop:disable RSpec/FilePath
  describe "when parsing a [1-ficr1.100m] 'results' valid section buffer," do
    let(:format_filepath) { 'app/strategies/pdf_results/formats/1-ficr1.100m.yml' }
    let(:layout_def) { YAML.load_file(format_filepath) }
    let(:target_ctx_name) { 'results' }
    let(:context_props) do
      # layout_def = { format_name => array_of_context_def_hash_props }
      props = layout_def.values.first.find { |hsh| hsh['name'] == target_ctx_name }
      # Clear out parent link so we can instantiate just 1 context:
      props['parent'] = nil
      props
    end

    # This should include all rows to be parsed per context:
    let(:src_rows) do
<<~DOC
7     FILIBUSTIERI MARGIOTTO                   6       ITA                30.20       1:01.92                           1:01.92
      ODYSSEA 2001 NELLO SPAZIO                        1998                           (31.72)                            787,62
DOC
    end

    let(:obj_instance) { described_class.new(context_props) }

    before(:each) do
      expect(context_props).to be_an(Hash).and be_present
      expect(obj_instance).to be_a(described_class)
      expect(src_rows).to be_a(String).and be_present
    end

    describe '#valid?' do
      it 'is true when the scan is aligned at the proper starting index' do
        expect(obj_instance.valid?(src_rows, 0)).to be true
      end
    end

    describe 'expected field values' do
      before(:each) { obj_instance.valid?(src_rows, 0) }

      {
        rank: '7',
        swimmer_name: 'FILIBUSTIERI MARGIOTTO',
        lane_num: '6',
        nation: 'ITA',
        lap50: '30.20',
        lap100: '1:01.92',
        timing: '1:01.92',
        team_name: 'ODYSSEA 2001 NELLO SPAZIO',
        year_of_birth: '1998',
        delta100: '31.72',
        std_score: '787,62'
      }.each do |expected_field, expected_value|
        it "has the expected '#{expected_field}'" do
          expect(obj_instance.dao.fields_hash[expected_field.to_s]).to eq(expected_value)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe "[1-ficr1.4x100] format" do
    let(:format_filepath) { 'app/strategies/pdf_results/formats/1-ficr1.4x100m.yml' }
    let(:layout_def) { YAML.load_file(format_filepath) }

    # This should include all rows to be parsed per context, but won't parse the next sibling context
    # in chain: (i.e.: after a 'rel_team' it won't scan for a 'rel_swimmer')
    let(:src_rows) do
<<~DOC
1     SUPER NUOTO 2001 ODISSEA ASD              4      ITA                34.19      1:10.92    1:45.69       2:25.57   2:57.63   3:36.38      4:05.34    4:36.35        4:36.35
      SUPER NUOTO 2001 ODISSEA ASD                                                   (36.73)    (34.77)       (39.88)   (32.06)   (38.75)      (28.96)    (31.01)

      SBROMBOLI FELIPE                                        ITA         34.19      1:10.92

                                                             1996                    (36.73)

      SCRONDOLO CROSTELLO                                     ITA         34.77      1:14.65

                                                             1985                    (39.88)

      CACCOLI VERACE                                          ITA         32.06      1:10.81

                                                             1991                    (38.75)

      LAMENNA POIBASTA                                        ITA         28.96       59.97

                                                             1997                    (31.01)
DOC
    end

    context "when parsing a 'rel_team' valid section buffer," do
      let(:target_ctx_name) { 'rel_team' }
      let(:context_props) do
        # layout_def = { format_name => array_of_context_def_hash_props }
        props = layout_def.values.first.find { |hsh| hsh['name'] == target_ctx_name }
        # Clear out parent link so we can instantiate just 1 context:
        props['parent'] = nil
        props
      end

      let(:obj_instance) { described_class.new(context_props) }

      before(:each) do
        expect(context_props).to be_an(Hash).and be_present
        expect(obj_instance).to be_a(described_class)
        expect(src_rows).to be_a(String).and be_present
      end

      describe '#valid?' do
        it 'is true when the scan is aligned at the proper starting index' do
          expect(obj_instance.valid?(src_rows, 0)).to be true
        end
      end

      describe 'expected field values' do
        before(:each) { obj_instance.valid?(src_rows, 0) }

        {
          rank: '1',
          team_name: 'SUPER NUOTO 2001 ODISSEA ASD',
          lane_num: '4',
          nation: 'ITA',
          lap50: '34.19',
          lap100: '1:10.92',
          lap150: '1:45.69',
          lap200: '2:25.57',
          lap250: '2:57.63',
          lap300: '3:36.38',
          lap350: '4:05.34',
          lap400: '4:36.35',
          timing: '4:36.35',
          delta100: '36.73',
          delta150: '34.77',
          delta200: '39.88',
          delta250: '32.06',
          delta300: '38.75',
          delta350: '28.96',
          delta400: '31.01'
        }.each do |expected_field, expected_value|
          it "has the expected '#{expected_field}'" do
            expect(obj_instance.dao.fields_hash[expected_field.to_s]).to eq(expected_value)
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    context "when parsing all the 'rel_swimmer' sections of a single relay data buffer," do
      let(:target_ctx_name) { 'rel_swimmer' }
      let(:context_props) do
        # layout_def = { format_name => array_of_context_def_hash_props }
        props = layout_def.values.first.find { |hsh| hsh['name'] == target_ctx_name }
        # Clear out parent link so we can instantiate just 1 context:
        props['parent'] = nil
        props
      end

      let(:obj_instance) { described_class.new(context_props) }
      let(:checked_fields) { %i[swimmer_name nation lap50 lap100 delta100 year_of_birth] }

      before(:each) do
        expect(context_props).to be_an(Hash).and be_present
        expect(obj_instance).to be_a(described_class)
        expect(src_rows).to be_a(String).and be_present
      end

      [
        { start_at: 3, swimmer_name: 'SBROMBOLI FELIPE', nation: 'ITA', lap50: '34.19',
          lap100: '1:10.92', year_of_birth: '1996', delta100: '36.73' },
        { start_at: 7, swimmer_name: 'SCRONDOLO CROSTELLO', nation: 'ITA', lap50: '34.77',
          lap100: '1:14.65', year_of_birth: '1985', delta100: '39.88' },
        { start_at: 11, swimmer_name: 'CACCOLI VERACE', nation: 'ITA', lap50: '32.06',
          lap100: '1:10.81', year_of_birth: '1991', delta100: '38.75' },
        { start_at: 15, swimmer_name: 'LAMENNA POIBASTA', nation: 'ITA', lap50: '28.96',
          lap100: '59.97', year_of_birth: '1997', delta100: '31.01' }
      ].each do |exp_hash|
        describe "the swimmer data starting at line #{exp_hash[:start_at]}" do
          it 'has the expected field values' do
            expect(obj_instance.valid?(src_rows, exp_hash[:start_at])).to be true
            checked_fields.each do |key|
              expect(obj_instance.dao.fields_hash[key.to_s]).to eq(exp_hash[key])
            end
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
# rubocop:enable Layout/HeredocIndentation, Layout/IndentationWidth, RSpec/SpecFilePathFormat
