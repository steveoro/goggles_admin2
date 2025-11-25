# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Phase3::RelayEnrichmentDetector, type: :service do
  let(:season) { GogglesDb::Season.find(242) } # Use existing season from fixtures
  let(:meeting_date) { '2025-06-24' }

  describe '#detect' do
    context 'with orphan swimmers in Phase 3 dictionary' do
      let(:source_path) { Rails.root.join('spec/fixtures/files/relay_l4_sample.json') }
      let(:phase3_swimmers) do
        [
          # Swimmer in dictionary with missing gender (should appear in enrichment)
          {
            'key' => '|ANTONIAZZI|Giorgia|1999',
            'last_name' => 'ANTONIAZZI',
            'first_name' => 'Giorgia',
            'year_of_birth' => 1999,
            'gender_type_code' => nil, # MISSING
            'complete_name' => 'ANTONIAZZI Giorgia',
            'swimmer_id' => nil,
            'category_type_id' => nil,
            'category_type_code' => nil
          },
          # Swimmer in dictionary with missing year (should appear in enrichment)
          {
            'key' => '|ROSSI|Mario|',
            'last_name' => 'ROSSI',
            'first_name' => 'Mario',
            'year_of_birth' => nil, # MISSING
            'gender_type_code' => 'M',
            'complete_name' => 'ROSSI Mario',
            'swimmer_id' => nil
          },
          # Swimmer already matched (should NOT appear)
          {
            'key' => 'M|VERDI|Giuseppe|1980',
            'last_name' => 'VERDI',
            'first_name' => 'Giuseppe',
            'year_of_birth' => 1980,
            'gender_type_code' => 'M',
            'complete_name' => 'VERDI Giuseppe',
            'swimmer_id' => 123, # HAS ID - matched
            'category_type_id' => 456,
            'category_type_code' => 'M45'
          },
          # Swimmer with all data but no ID (only missing_swimmer_id)
          {
            'key' => 'F|BIANCHI|Anna|1985',
            'last_name' => 'BIANCHI',
            'first_name' => 'Anna',
            'year_of_birth' => 1985,
            'gender_type_code' => 'F',
            'complete_name' => 'BIANCHI Anna',
            'swimmer_id' => nil,
            'category_type_id' => 789,
            'category_type_code' => 'M40'
          }
        ]
      end

      before(:each) do
        # Create minimal source file with no relay results (to test orphan detection)
        FileUtils.mkdir_p(File.dirname(source_path))
        File.write(source_path, { 'sections' => [] }.to_json)
      end

      after(:each) do
        FileUtils.rm_f(source_path)
      end

      it 'detects orphan swimmers with missing gender' do
        detector = described_class.new(
          source_path: source_path,
          phase3_swimmers: phase3_swimmers,
          season: season,
          meeting_date: meeting_date
        )

        result = detector.detect

        expect(result).not_to be_empty
        orphan_group = result.find { |r| r['relay_label'].include?('Orphan') }
        expect(orphan_group).to be_present

        orphan_swimmers = orphan_group['swimmers']
        expect(orphan_swimmers.size).to eq(3) # ANTONIAZZI, ROSSI, BIANCHI (not VERDI - has ID)

        # Check ANTONIAZZI has missing_gender issue
        antoniazzi = orphan_swimmers.find { |s| s['name'].include?('ANTONIAZZI') }
        expect(antoniazzi).to be_present
        expect(antoniazzi['issues']['missing_gender']).to be true
        expect(antoniazzi['issues']['missing_swimmer_id']).to be true
      end

      it 'detects orphan swimmers with missing year_of_birth' do
        detector = described_class.new(
          source_path: source_path,
          phase3_swimmers: phase3_swimmers,
          season: season,
          meeting_date: meeting_date
        )

        result = detector.detect
        orphan_group = result.find { |r| r['relay_label'].include?('Orphan') }
        orphan_swimmers = orphan_group['swimmers']

        # Check ROSSI has missing_year_of_birth issue
        rossi = orphan_swimmers.find { |s| s['name'].include?('ROSSI') }
        expect(rossi).to be_present
        expect(rossi['issues']['missing_year_of_birth']).to be true
        expect(rossi['issues']['missing_swimmer_id']).to be true
      end

      it 'does not include swimmers already matched with swimmer_id' do
        detector = described_class.new(
          source_path: source_path,
          phase3_swimmers: phase3_swimmers,
          season: season,
          meeting_date: meeting_date
        )

        result = detector.detect
        orphan_group = result.find { |r| r['relay_label'].include?('Orphan') }
        orphan_swimmers = orphan_group['swimmers']

        # VERDI should not appear (has swimmer_id)
        verdi = orphan_swimmers.find { |s| s['name'].include?('VERDI') }
        expect(verdi).to be_nil
      end

      it 'includes swimmers with only missing_swimmer_id issue' do
        detector = described_class.new(
          source_path: source_path,
          phase3_swimmers: phase3_swimmers,
          season: season,
          meeting_date: meeting_date
        )

        result = detector.detect
        orphan_group = result.find { |r| r['relay_label'].include?('Orphan') }
        orphan_swimmers = orphan_group['swimmers']

        # BIANCHI should appear (has all data but no swimmer_id)
        bianchi = orphan_swimmers.find { |s| s['name'].include?('BIANCHI') }
        expect(bianchi).to be_present
        expect(bianchi['issues']['missing_swimmer_id']).to be true
        expect(bianchi['issues']['missing_gender']).to be false
        expect(bianchi['issues']['missing_year_of_birth']).to be false
      end
    end
  end
end
