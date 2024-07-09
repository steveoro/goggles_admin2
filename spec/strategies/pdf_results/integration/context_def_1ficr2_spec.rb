# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Layout/HeredocIndentation, Layout/IndentationWidth, RSpec/SpecFilePathFormat
RSpec.describe PdfResults::ContextDef, type: :integration do
  let(:format_filepath) { 'app/strategies/pdf_results/formats/1-ficr2.4x050m.yml' }
  let(:layout_def) { YAML.load_file(format_filepath) }

  # This should include all rows to be parsed per context, but won't parse the next sibling context
  # in chain: (i.e.: after a 'rel_team' it won't scan for a 'rel_swimmer')
  let(:src_rows) do
<<~DOC
6     CSI NUOTO OBER FERRARI                   1       ITA                27.00     1:04.62      1:48.49       2:15.47   2:15.47
      CSI NUOTO OBER FERRARI                                                         (37.62)     (43.87)       (26.98)    758,17
      VIANI TOMMASO                                          ITA         27.00
                                                          1995
      SESENA BARBARA                                         ITA         37.62
                                                          1971
      BIANCHI ELENA                                          ITA         43.87
                                                          1967
      MARAMOTTI RICCARDO                                     ITA         26.98
                                                          1998
DOC
  end

  describe "when parsing a [1-ficr2-4x50] 'rel_team' valid section buffer," do
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
        rank: '6',
        team_name: 'CSI NUOTO OBER FERRARI',
        lane_num: '1',
        nation: 'ITA',
        lap50: '27.00',
        lap100: '1:04.62',
        lap150: '1:48.49',
        lap200: '2:15.47',
        timing: '2:15.47',
        delta100: '37.62',
        delta150: '43.87',
        delta200: '26.98',
        std_score: '758,17'
      }.each do |expected_field, expected_value|
        it "has the expected '#{expected_field}'" do
          expect(obj_instance.dao.fields_hash[expected_field.to_s]).to eq(expected_value)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe "when parsing a [1-ficr2-4x50] 'rel_swimmer' valid section buffer," do
    let(:target_ctx_name) { 'rel_swimmer' }
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

    context 'when checking all the swimmers in a single relay section' do
      [
        { start_at: 2, swimmer_name: 'VIANI TOMMASO', nation: 'ITA', lap50: '27.00', year_of_birth: '1995' },
        { start_at: 4, swimmer_name: 'SESENA BARBARA', nation: 'ITA', lap50: '37.62', year_of_birth: '1971' },
        { start_at: 6, swimmer_name: 'BIANCHI ELENA', nation: 'ITA', lap50: '43.87', year_of_birth: '1967' },
        { start_at: 8, swimmer_name: 'MARAMOTTI RICCARDO', nation: 'ITA', lap50: '26.98', year_of_birth: '1998' }
      ].each do |exp_hash|
        describe "the swimmer data starting at line #{exp_hash[:start_at]}" do
          it 'has the expected field values' do
            expect(obj_instance.valid?(src_rows, exp_hash[:start_at])).to be true
            expect(obj_instance.dao.fields_hash['swimmer_name']).to eq(exp_hash[:swimmer_name])
            expect(obj_instance.dao.fields_hash['nation']).to eq(exp_hash[:nation])
            expect(obj_instance.dao.fields_hash['lap50']).to eq(exp_hash[:lap50])
            expect(obj_instance.dao.fields_hash['year_of_birth']).to eq(exp_hash[:year_of_birth])
          end
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
# rubocop:enable Layout/HeredocIndentation, Layout/IndentationWidth, RSpec/SpecFilePathFormat
