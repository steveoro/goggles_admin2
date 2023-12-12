# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::ContextDef, type: :integration do
  let(:props_1ficr1_results_popout) do
    {
      name: 'results',
      fields: [
        { name: 'rank',         format: "\\s?(\\d{1,2}|SQ)" },
        { name: 'swimmer_name', format: "\\s+(\\w+(\\s\\w+){1,4})\\s+", token_end: 45 },
        { name: 'nation',       format: "\\s+\\s(\\w{2,3})\\s\\s+" },
        { name: 'birth_year',   format: "\\s+\\s(\\d{4})\\s\\s+" },
        { name: 'team_name',    format: "\\s+\\s([\\w\\d]+(\\s[\\w\\d&.-]+)+)\\s\\s+" },
        { name: 'heat_num',     format: "\\s*(\\d{1,3})\\s*" },
        { name: 'lane_num',     format: "\\s*(\\d{1,2})\\s*" },
        { name: 'heat_rank',    format: "\\s*(\\d{1,2}|SQ)\\s*" },
        { name: 'timing',       format: "\\s*(\\d{1,2}?[':.]?\\d{1,2}[\":.]\\d{1,2})\\s*" },
        { name: 'team_score',   format: "\\s*(.+)\\s*", required: false },
        { name: 'dsq_type',     format: "\\s*(.+)\\b", required: false },
        { name: 'std_score',    format: "\\s*(\\d{1,4}[,.]\\d{1,2})\\b", required: false }
      ]
    }
  end

  let(:props_1ficr1_results_indexes) do
    {
      name: 'results',
      fields: [
        { name: 'rank',         pop_out: false, format: "\\s?(\\d{1,2}|SQ)" },
        { name: 'swimmer_name', pop_out: false, format: "\\s+(\\w+(\\s\\w+){1,4})\\s+", token_end: 45 },
        { name: 'nation',       pop_out: false, format: "\\s+\\s(\\w{2,3})\\s\\s+" },
        { name: 'birth_year',   pop_out: false, format: "\\s+\\s(\\d{4})\\s\\s+" },
        { name: 'team_name',    pop_out: false, format: "\\s*([\\w\\d]+(\\s[\\w\\d&.-]+)+)\\s\\s+", token_start: 88 },
        { name: 'heat_num',     pop_out: false, format: "\\s*(\\d{1,3})\\s*", token_start: 122 },
        { name: 'lane_num',     pop_out: false, format: "\\s*(\\d{1,2})\\s*", token_start: 127 },
        { name: 'heat_rank',    pop_out: false, format: "\\s*(\\d{1,2}|SQ)\\s*", token_start: 133 },
        { name: 'timing',       pop_out: false, format: "\\s*(\\d{1,2}?[':.]?\\d{1,2}[\":.]\\d{1,2})\\s*", token_start: 138 },
        { name: 'team_score',   pop_out: false, format: "\\s*(.+)\\s*", required: false, token_start: 146 },
        { name: 'dsq_type',     pop_out: false, format: "\\s*(.+)\\b", required: false, token_start: 146 },
        { name: 'std_score',    pop_out: false, format: "\\s*(\\d{1,4}[,.]\\d{1,2})\\b", required: false, token_start: 146 }
      ]
    }
  end

  let(:props_1ficr1_footer_popout) do
    {
      name: 'results',
      eop: true,
      row_span: 6,
      starts_with: "Elaborazione dati a cura della Federazione Italiana Cronometristi -",
      fields: [
        { name: 'pool_type',      format: "\\s*www.ficr.it\\s+(\\d{1,2} corsie \\d{2}m)\\s+Pagina\\s*" },
        { name: 'page_delimiter', format: "\\s*Risultati su https://nuoto.ficr.it\\b" }
      ]
    }
  end

  [
    {
      src_buffer: [
        ' 5    MASTIKAZZI GIOANNA                                             ITA          2002   FOGLIATA 20.30 SSD                7     7     5    38.04',
        ' 6    SUCRALOSIO PEPPONA                                             ITA          2000   PARCO MARCO SSD                   4     2     5    42.83',
        '                                                   A20 Under Maschi',
        '',
        ' 1    MOSCARDINO FILIBERTO                                           ITA          2000   ZIO MASCALZO TEAM SSD             26    1     2    27.03',
        ' 2    SBIRIGUDA GIOVANNI                                             ITA          2003   SPORT ANCHENO 3.0 SSD             28    7     5    27.66'
      ],
      props: :props_1ficr1_results_popout
    },
    {
      src_buffer: [
        'Elaborazione dati a cura della Federazione Italiana Cronometristi - www.ficr.it                    8 corsie 25m                                           Pagina 1 di 5',
        '',
        '',
        '',
        '',
        '                                                                                    Risultati su https://nuoto.ficr.it'
      ],
      props: :props_1ficr1_footer_popout
    }
  ].each_with_index do |def_hash, idx|
    context "for a buffer of lines satisfying all conditions (#{def_hash[:props]})," do
      let(:obj_instance) do
        described_class.new(send(def_hash[:props]))
      end

      before do
        expect(def_hash[:src_buffer]).to be_an(Array).and be_present
        expect(obj_instance).to be_a(described_class)
        expect(obj_instance.log).to be_blank
      end

      describe '#valid?' do
        it 'is true when the scan is aligned at the proper starting index' do
          # DEBUG
          puts '=> ' + obj_instance.name
          expect(def_hash[:src_buffer]).to be_an(Array)
          expect(def_hash[:src_buffer].count).to eq(6)
          expect(obj_instance.valid?(def_hash[:src_buffer], 0)).to be true

          if idx.zero? # Additional tests for the first case:
            expect(obj_instance.valid?(def_hash[:src_buffer], 1)).to be true
            expect(obj_instance.valid?(def_hash[:src_buffer], 2)).to be false # A20
            expect(obj_instance.valid?(def_hash[:src_buffer], 3)).to be false # blank
            expect(obj_instance.valid?(def_hash[:src_buffer], 4)).to be true
          end
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
