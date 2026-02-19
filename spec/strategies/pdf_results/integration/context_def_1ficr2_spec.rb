# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Layout/IndentationWidth, RSpec/SpecFilePathFormat
RSpec.describe PdfResults::ContextDef, type: :integration do
  let(:format_filepath) { 'app/strategies/pdf_results/formats/1-ficr2.4x050m.yml' }
  let(:layout_def) { YAML.load_file(format_filepath) }

  describe "when parsing a [1-ficr2-4x50] 'rel_team' valid section buffer," do
    let(:target_ctx_name) { 'rel_team' }
    let(:context_props) do
      props = layout_def.values.first.find { |hsh| hsh['name'] == target_ctx_name }
      props['parent'] = nil
      props.delete('starts_at_row')
      props
    end

    let(:obj_instance) { described_class.new(context_props) }

    let(:src_rows) do
<<-DOC
   6  (M120) - CSI NUOTO OBER FERRARI                                1  2    27.00     1:04.62      1:48.49       2:15.47
                                                    1       (37.62)     (43.87)
DOC
    end

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
        cat_title: '120',
        team_name: 'CSI NUOTO OBER FERRARI'
      }.each do |expected_field, expected_value|
        it "has the expected '#{expected_field}'" do
          expect(obj_instance.dao).to be_present
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
      props = layout_def.values.first.find { |hsh| hsh['name'] == target_ctx_name }
      props['parent'] = nil
      props.delete('starts_at_row')
      props
    end

    let(:obj_instance) { described_class.new(context_props) }

    let(:src_rows) do
<<-DOC
      VIANI TOMMASO                                          1995         27.00

      SESENA BARBARA                                         1971         37.62

      BIANCHI ELENA                                          1967         43.87

      MARAMOTTI RICCARDO                                     1998         26.98

DOC
    end

    before(:each) do
      expect(context_props).to be_an(Hash).and be_present
      expect(obj_instance).to be_a(described_class)
      expect(src_rows).to be_a(String).and be_present
    end

    context 'when checking all the swimmers in a single relay section' do
      [
        { start_at: 0, swimmer_name: 'VIANI TOMMASO', year_of_birth: '1995', swimmer_delta: '27.00' },
        { start_at: 2, swimmer_name: 'SESENA BARBARA', year_of_birth: '1971', swimmer_delta: '37.62' },
        { start_at: 4, swimmer_name: 'BIANCHI ELENA', year_of_birth: '1967', swimmer_delta: '43.87' },
        { start_at: 6, swimmer_name: 'MARAMOTTI RICCARDO', year_of_birth: '1998', swimmer_delta: '26.98' }
      ].each do |exp_hash|
        describe "the swimmer data starting at line #{exp_hash[:start_at]}" do
          it 'has the expected field values' do
            expect(obj_instance.valid?(src_rows, exp_hash[:start_at])).to be true
            expect(obj_instance.dao.fields_hash['swimmer_name']).to eq(exp_hash[:swimmer_name])
            expect(obj_instance.dao.fields_hash['year_of_birth']).to eq(exp_hash[:year_of_birth])
            expect(obj_instance.dao.fields_hash['swimmer_delta']).to eq(exp_hash[:swimmer_delta])
          end
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
# rubocop:enable Layout/IndentationWidth, RSpec/SpecFilePathFormat
