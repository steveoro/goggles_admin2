# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatch::Extractor do
  let(:fixture_html) { Rails.root.join('spec/fixtures/files/federnuoto/riepilogo-eventi.html').read }

  describe '#call' do
    subject(:snapshot) { described_class.new(fixture_html).call }

    it 'returns a Snapshot with all the meeting rows from each yearly table' do
      expect(snapshot).to be_a(described_class::Snapshot)
      expect(snapshot.rows.size).to eq(10)
      expect(snapshot.rows.pluck('year').uniq).to eq(%w[2026 2027])
    end

    it 'extracts the row fields, with absolute result links' do
      expect(snapshot.rows.first).to eq(
        'year' => '2026', 'date' => '24/10', 'name' => 'Distanze Speciali Campania', 'place' => 'Napoli',
        'url' => "#{FedernuotoWatch::BASE_URL}/home/master/circuito-supermaster/eventi-circuito-supermaster.html" \
                 '#/risultati/150091:distanze-speciali-campania-2026.html',
        'info' => '', 'key' => '2026 | 24/10 | Distanze Speciali Campania | Napoli'
      )
    end

    it 'leaves blank url & info for rows without results (non-breaking spaces only)' do
      expect(snapshot.rows.last).to include('name' => '2° Meeting Valdinievole', 'url' => '', 'info' => '')
    end

    it 'skips the header rows' do
      expect(snapshot.rows.pluck('date')).not_to include('Data')
    end

    it 'returns the normalized text of the component section only (no scripts, header or footer)' do
      expect(snapshot.text).to start_with("Riepilogo gare Supermaster 2026-2027\n2026\n")
      expect(snapshot.text).not_to include('should be ignored', 'Footer', 'Menu')
      expect(snapshot.text.lines.map(&:strip)).not_to include('')
    end

    it 'returns a stable SHA256 digest' do
      expect(snapshot.digest).to match(/\A\h{64}\z/)
      expect(described_class.new(fixture_html).call.digest).to eq(snapshot.digest)
    end

    it 'changes the digest when a results link is published, even if the visible text stays the same' do
      updated_html = fixture_html.sub(
        "<td>Trento</td>\n<td>&nbsp;</td>",
        "<td>Trento</td>\n<td><a href=\"/home/results/1.html\"><img src=\"/images/images/scheda.png\" alt=\"icon\"></a></td>"
      )
      updated = described_class.new(updated_html).call

      expect(updated.text).to eq(snapshot.text)
      expect(updated.digest).not_to eq(snapshot.digest)
      expect(updated.rows.find { |row| row['place'] == 'Trento' }['url']).to eq("#{FedernuotoWatch::BASE_URL}/home/results/1.html")
    end

    it 'stores any text of the last column as info (e.g. a cancellation note)' do
      updated_html = fixture_html.sub("<td>Bari</td>\n<td>&nbsp;</td>", "<td>Bari</td>\n<td>ANNULLATA</td>")
      row = described_class.new(updated_html).call.rows.find { |r| r['place'] == 'Bari' }
      expect(row).to include('info' => 'ANNULLATA', 'url' => '')
    end
  end

  context 'when the component section is missing' do
    it 'raises a ParseError' do
      expect { described_class.new('<html><body><main><p>Maintenance</p></main></body></html>').call }
        .to raise_error(FedernuotoWatch::ParseError)
    end
  end

  context 'when the section has no calendar tables' do
    it 'returns no rows but still a text digest' do
      snapshot = described_class.new('<main><section id="component"><p>Coming soon</p></section></main>').call
      expect(snapshot.rows).to eq([])
      expect(snapshot.text).to eq('Coming soon')
      expect(snapshot.digest).to be_present
    end
  end
end
