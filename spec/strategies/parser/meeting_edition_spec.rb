# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe MeetingEdition, type: :strategy do
    describe 'self.from_l2_result' do
      let(:descriptions) { YAML.load_file(Rails.root.join('spec/fixtures/parser/descriptions-212.yml')) }

      describe 'with valid parameters,' do
        let(:random_edition) { (rand * 25).to_i }
        let(:no_edition_desc) { "#{%w[Trofeo Memorial Meeting].sample} #{FFaker::NameIT.name}" }
        let(:roman_edition_desc) { "#{random_edition.to_roman}#{['°', '^', ''].sample} #{no_edition_desc}" }
        let(:arabic_edition_desc) { "#{random_edition}#{['°', '^', ''].sample} #{no_edition_desc}" }
        #-- -------------------------------------------------------------------
        #++

        context "when parsing a format without any edition number," do
          it 'returns EditionType::NONE_ID and no edition value' do
            edition_type_id, edition = described_class.from_l2_result(no_edition_desc)
            expect(edition_type_id).to eq(GogglesDb::EditionType::NONE_ID)
            expect(edition).to be nil
          end
        end

        context "when parsing a YEARLY edition format (with multiple checks)," do
          [
            'Campionati Regionali Master',
            'Campionati Reg. Master - EMI 2020',
            'Camp. Reg. Lazio 2020',
            'Campionato Italiano su base regionale Emilia-Romagna',
            'Campionato Provinciale Master',
            'Campionato Regionale Master Emilia 2021',
            'Camp. Reg. Master, Finali 2021 - Piemonte',
            'Distanze speciali Lombardia 2020'
          ].each do |yearly_edition_desc|
            it 'returns EditionType::YEARLY_ID and the year as the edition value' do
              edition_type_id, edition = described_class.from_l2_result(yearly_edition_desc)
              expect(edition_type_id).to eq(GogglesDb::EditionType::YEARLY_ID)
              if yearly_edition_desc =~ /\s\d{4}$/
                reg = Regexp.new(/\s(\d{4})$/u)
                expect(edition).to eq(yearly_edition_desc.match(reg).captures.first.to_i)
              else
                expect(edition).to eq(Time.zone.today.year)
              end
            end
          end
        end

        context "when parsing a SEASONAL edition format (with multiple checks)," do
          it 'returns EditionType::SEASONAL_ID and the edition value' do
            [
              'Prova', 'Prova finale', 'Prova Finale Reg.',
              'Finale', 'Finali Reg.', 'Prova Camp. regionale',
              'Meeting Camp. Reg.', 'Meeting regionale', 'Meeting Reg.'].each do |desc|
              fixture_edition = 1 + (rand * 7).to_i
              seasonal_edition_desc = "#{fixture_edition}#{['°', 'a', 'o'].sample} #{desc} #{%w[CSI UISP RN ACSI].sample}"
              edition_type_id, edition = described_class.from_l2_result(seasonal_edition_desc)
              expect(edition_type_id).to eq(GogglesDb::EditionType::SEASONAL_ID)
              expect(edition).to eq(fixture_edition)
            end
          end
        end

        context "when parsing a ROMAN edition format using roman numbers (with multiple checks)," do
          it 'returns EditionType::ROMAN_ID and the edition value' do
            edition_type_id, edition = described_class.from_l2_result(roman_edition_desc)
            expect(edition_type_id).to eq(GogglesDb::EditionType::ROMAN_ID)
            expect(edition).to eq(random_edition)
          end
        end

        context "when parsing a ROMAN edition format using arabic numbers (with multiple checks)," do
          it 'returns EditionType::ROMAN_ID and the edition value' do
            edition_type_id, edition = described_class.from_l2_result(arabic_edition_desc)
            # DEBUG ----------------------------------------------------------------
            # puts "Parsing \"#{arabic_edition_desc}\""
            # binding.pry if edition_type_id != GogglesDb::EditionType::ROMAN_ID
            # ----------------------------------------------------------------------
            expect(edition_type_id).to eq(GogglesDb::EditionType::ROMAN_ID)
            expect(edition).to eq(random_edition)
          end
        end
        #-- -------------------------------------------------------------------
        #++
      end
    end
  end
end
