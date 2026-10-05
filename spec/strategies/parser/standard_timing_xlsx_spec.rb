# frozen_string_literal: true

require 'rails_helper'

module Parser # rubocop:disable Metrics/ModuleLength
  RSpec.describe StandardTimingXlsx, type: :strategy do
    let(:header) { ['KEY', 'CATEG', 'COD GARA', 'GARA', 'SESSO', 'VASCA', 'CENT TOT', 'TEMPO (mmsscc)', 'TEMPO PRINT', 'MIN', 'SEC', 'CENT'] }
    let(:data_rows) do
      [
        ['0M20F25', 'M20', 0, '50 STILE LIBERO', 'F', 25, 2448, '002448', '24.48', 0, 24, 48],
        ['0M20F50', 'M20', 0, '50 STILE LIBERO', 'F', 50, 2531, '002531', '25.31', 0, 25, 31],
        ['0M20M25', 'M20', 0, '50 STILE LIBERO', 'M', 25, 2132, '002132', '21.32', 0, 21, 32],
        ['0M20M50', 'M20', 0, '50 STILE LIBERO', 'M', 50, 2228, '002228', '22.28', 0, 22, 28]
      ]
    end

    # Serializes the given sheets to a temp file that outlives the block, yielding its path.
    def with_xlsx(sheets)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'test.xlsx')
        package = Axlsx::Package.new
        sheets.each do |defn|
          package.workbook.add_worksheet(name: defn[:name]) do |sheet|
            defn[:rows].each { |row| sheet.add_row(row) }
          end
        end
        package.serialize(path)
        yield path
      end
    end

    context 'with a single sheet covering both pool types' do
      it 'extracts normalized rows using only that sheet' do
        with_xlsx([{ name: 'VERIFICA', rows: [header] + data_rows }]) do |file|
          extractor = described_class.new(file)
          rows = extractor.rows

          expect(rows.size).to eq(4)
          expect(extractor.sheets_used).to eq(['VERIFICA'])
          expect(rows.first).to include(
            'category_code' => 'M20', 'event_label' => '50 STILE LIBERO',
            'gender' => 'F', 'pool_type' => '25', 'timing' => '24.48'
          )
        end
      end
    end

    context 'with per-pool sheets only' do
      it 'merges and de-duplicates all matching sheets' do
        s25 = [{ name: 'VASCA CORTA', rows: [header] + data_rows.select { |r| r[5] == 25 } }]
        s50 = [{ name: 'VASCA LUNGA', rows: [header] + data_rows.select { |r| r[5] == 50 } }]
        with_xlsx(s25 + s50) do |file|
          extractor = described_class.new(file)
          rows = extractor.rows

          expect(extractor.sheets_used).to eq(['VASCA CORTA', 'VASCA LUNGA'])
          expect(rows.size).to eq(4)
          expect(rows.pluck('pool_type').uniq.sort).to eq(%w[25 50])
        end
      end

      it 'warns on conflicting timings for the same row key' do
        rows_a = [header, ['k1', 'M20', 0, '50 STILE LIBERO', 'F', 25, 2448, '002448', '24.48']]
        rows_b = [header, ['k2', 'M20', 0, '50 STILE LIBERO', 'F', 25, 2449, '002449', '24.49']]
        with_xlsx([{ name: 'A', rows: rows_a }, { name: 'B', rows: rows_b }]) do |file|
          extractor = described_class.new(file)
          rows = extractor.rows

          expect(rows.size).to eq(1)
          expect(rows.first['timing']).to eq('24.48')
          expect(extractor.warnings.size).to eq(1)
        end
      end
    end

    context 'with a complete sheet plus partial duplicates' do
      it 'prefers the complete sheet alone' do
        s25 = data_rows.select { |r| r[5] == 25 }
        with_xlsx([
                    { name: 'VASCA CORTA', rows: [header] + s25 },
                    { name: 'VERIFICA', rows: [header] + data_rows }
                  ]) do |file|
          extractor = described_class.new(file)

          expect(extractor.sheets_used).to eq(['VERIFICA'])
          expect(extractor.rows.size).to eq(4)
        end
      end
    end

    context 'when normalizing gender codes' do
      it 'maps U/D to M/F' do
        rows = [header,
                ['k1', 'M20', 0, '50 STILE LIBERO', 'U', 25, 2448, '002448', '24.48'],
                ['k2', 'M20', 0, '50 STILE LIBERO', 'D', 25, 2448, '002448', '24.48']]
        with_xlsx([{ name: 'S', rows: rows }]) do |file|
          result = described_class.new(file).rows
          expect(result.pluck('gender')).to eq(%w[M F])
        end
      end
    end

    context 'when normalizing category codes' do
      it 'maps M100 to MA0' do
        rows = [header, ['k1', 'M100', 0, '50 STILE LIBERO', 'F', 25, 12_930, '020930', '2:09.30']]
        with_xlsx([{ name: 'S', rows: rows }]) do |file|
          result = described_class.new(file).rows
          expect(result.first['category_code']).to eq('MA0')
        end
      end
    end

    context 'with header label aliases' do
      it 'accepts CATEGORIA instead of CATEG' do
        alt_header = ['CATEGORIA', 'GARA', 'SESSO', 'VASCA', 'TEMPO PRINT']
        rows = [['M20', '50 STILE LIBERO', 'F', 25, '24.48']]
        with_xlsx([{ name: 'S', rows: [alt_header] + rows }]) do |file|
          result = described_class.new(file).rows
          expect(result.size).to eq(1)
          expect(result.first['category_code']).to eq('M20')
        end
      end
    end

    context 'when TEMPO PRINT is missing' do
      it "rebuilds timing from 'TEMPO (mmsscc)' digits" do
        alt_header = ['CATEG', 'GARA', 'SESSO', 'VASCA', 'TEMPO (mmsscc)']
        rows = [['M20', '50 STILE LIBERO', 'F', 25, '002448'],
                ['M20', '200 STILE LIBERO', 'F', 25, 118_26]]
        with_xlsx([{ name: 'S', rows: [alt_header] + rows }]) do |file|
          result = described_class.new(file).rows
          expect(result.pluck('timing')).to eq(['0:24.48', '1:18.26'])
        end
      end
    end

    context 'with blank rows' do
      it 'skips fully blank rows' do
        rows = [header, data_rows.first, [nil] * 12, [''] * 12, data_rows.last]
        with_xlsx([{ name: 'S', rows: rows }]) do |file|
          expect(described_class.new(file).rows.size).to eq(2)
        end
      end
    end

    context 'with no compatible sheet' do
      it 'raises an error' do
        with_xlsx([{ name: 'X', rows: [%w[foo bar baz], [1, 2, 3]] }]) do |file|
          expect { described_class.new(file).rows }.to raise_error(/No compatible sheet/)
        end
      end
    end
  end
end
