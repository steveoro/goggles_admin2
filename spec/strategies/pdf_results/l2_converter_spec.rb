# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::L2Converter, type: :strategy do
  subject { described_class.new(fixture_data) }

  let(:fixture_rows_count) { 5 }

  # (We'll deal with just the required fields & keys for the conversion)
  let(:result_rows) do
    Array.new(fixture_rows_count) do |idx|
      {
        name: 'results',
        fields: {
          'pos' => idx + 1,
          'name' => "#{FFaker::Name.last_name} #{FFaker::Name.first_name}",
          'year' => 18.years.ago.year - ((rand * 100) % 70).to_i,
          'sex' => %w[M F].sample,
          'team' => "#{FFaker::Address.city} S.C. #{Time.zone.now.year}",
          'timing' => "#{(rand % 2).to_i}'#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'score' => (rand * 1000).to_i,
          'lane_num' => (rand * 10).to_i,
          'nation' => %w[ITA AUS DEU FRA UK].sample,
          'lap50' => "#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'lap100' => "#{(rand % 2).to_i}'#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'lap150' => "#{((rand * 2) % 2).to_i}'#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'lap200' => "#{((rand * 2) % 2).to_i}'#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'delta100' => "#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'delta150' => "#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}",
          'delta200' => "#{((rand * 59) % 59).to_i}\"#{((rand * 59) % 59).to_i}"
        }
      }
    end
  end

  let(:event_hash) do
    {
      name: 'event',
      fields: {
        'event_length' => [50, 100, 200].sample,
        'event_type' => %w[Rana Dorso Farafalla Stile].sample
      },
      rows: [
        {
          name: 'category',
          # L2Converter takes category values directly from its key:
          key: "M#{20 + ((rand * 5).to_i * 10)} Master #{%w[Mas Fem].sample}",
          rows: result_rows
        },
        {
          name: 'footer',
          fields: {
            'pool_type' => [25, 50].sample
          }
        }
      ]
    }
  end

  let(:fixture_data) do
    {
      name: 'header',
      fields: {
        'edition' => (rand * 25).to_i,
        'meeting_name' => "#{FFaker::Name.suffix} #{FFaker::Address.city} Meeting",
        'meeting_place' => FFaker::Address.city,
        'meeting_date' => FFaker::Time.date.strftime('%d/%m/%Y')
      },
      rows: [
        event_hash
      ]
    }
  end

  before(:each) do
    expect(fixture_data).to be_an(Hash).and be_present
    expect(fixture_data[:name]).to eq('header')
    expect(fixture_data[:rows].first[:name]).to eq('event')
    expect(fixture_data[:rows].first[:rows].first[:name]).to eq('category')
    expect(fixture_data[:rows].first[:rows].last[:name]).to eq('footer')
  end

  describe 'a new instance,' do
    context 'when initialized with an invalid data_hash,' do
      it 'raises an error' do
        expect { described_class.new({ name: 'unsupported' }) }.to raise_error('Invalid data_hash specified!')
      end
    end

    context 'when initialized with a proper data_hash,' do
      it 'does not raise any error' do
        expect { subject }.not_to raise_error
      end

      it_behaves_like(
        'responding to a list of methods',
        %i[
          header event_sections to_hash
        ]
      )

      describe '#header' do
        it 'returns a non-empty Hash' do
          expect(subject.header).to be_an(Hash).and be_present
        end

        it 'has the layoutType 2' do
          expect(subject.header['layoutType']).to eq(2)
        end

        it 'includes the Meeting name or description' do
          expect(subject.header['name']).to eq("#{fixture_data[:fields]['edition']}° #{fixture_data[:fields]['meeting_name']}")
        end

        it 'includes the session date' do
          expect(subject.header['dateDay1']).to eq(fixture_data[:fields]['meeting_date'].to_s.split('/').first)
          month_index = fixture_data[:fields]['meeting_date'].to_s.split('/').second.to_i
          expect(subject.header['dateMonth1']).to eq(Parser::SessionDate::MONTH_NAMES[month_index])
          expect(subject.header['dateYear1']).to eq(fixture_data[:fields]['meeting_date'].to_s.split('/').last)
        end

        it 'includes the session place' do
          expect(subject.header['address1']).to eq(fixture_data[:fields]['meeting_place'])
        end

        it 'includes the pool length' do
          expect(subject.header['poolLength']).to eq(
            fixture_data[:rows].first[:rows].last[:fields]['pool_type']
          )
        end
      end

      describe '#event_sections' do
        it 'returns a non-empty Array' do
          expect(subject.event_sections).to be_an(Array).and be_present
        end

        # (Testing with just 1 event for simplicity)
        it 'includes the event title' do
          expect(subject.event_sections.first['title']).to eq(
            "#{event_hash[:fields]['event_length']} #{event_hash[:fields]['event_type']}"
          )
        end

        it 'includes the category code' do
          expect(subject.event_sections.first['fin_sigla_categoria'])
            .to eq(event_hash[:rows].first[:key].split.first)
        end

        it 'includes the category gender' do
          expect(subject.event_sections.first['fin_sesso'])
            .to eq(event_hash[:rows].first[:key].split.third[0])
        end

        it 'includes as many result rows as the fixture data' do
          expect(subject.event_sections.first['rows'].count).to eq(fixture_rows_count)
        end

        it 'includes all expected key fields for each result row' do
          subject.event_sections.first['rows'].each do |result_row|
            expect(result_row.keys).to match_array(
              %w[pos name year sex team timing score lane_num nation lap50 lap100 lap150 lap200 delta100 delta150 delta200]
            )
          end
        end
      end

      describe '#to_hash' do
        it 'returns a non-empty Hash' do
          expect(subject.to_hash).to be_an(Hash).and be_present
        end

        it 'is the merged result of #header and #event_sections' do
          expect(subject.to_hash).to eq(
            subject.header.merge('sections' => subject.event_sections)
          )
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
#-- ---------------------------------------------------------------------------
#++
