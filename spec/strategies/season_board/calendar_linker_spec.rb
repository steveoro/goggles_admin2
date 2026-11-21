# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe SeasonBoard::CalendarLinker do
  let(:data_root) { Dir.mktmpdir }
  let(:season) { FactoryBot.create(:season, season_type: GogglesDb::SeasonType.mas_fin) }
  let(:meeting) { FactoryBot.create(:meeting, season:) }
  let!(:calendar) { FactoryBot.create(:calendar, meeting:, season:) }
  let(:fin_url) do
    'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html' \
      '#/risultati/150100:23-trofeo-de-akker.html'
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def link(**opts)
    described_class.new(season:, calendar_id: calendar.id, fin_event_id: '150100', data_root:, **opts).call
  end

  context 'with valid parameters' do
    subject(:result) { link(results_link: fin_url) }

    it 'is successful' do
      expect(result).to be_success
      expect(result.error).to be_nil
    end

    it 'updates the calendar row locally' do
      result
      calendar.reload
      expect(calendar.results_code).to eq('150100')
      expect(calendar.results_link).to eq(fin_url)
    end

    it 'writes a numbered SQL file in results.new/<season>' do
      FileUtils.mkdir_p(File.join(data_root, 'results.sent', season.id.to_s))
      File.write(File.join(data_root, 'results.sent', season.id.to_s, '0444-some-lt4.sql'), '-- x')
      expect(result.sql_path.to_s).to eq(
        File.join(data_root, 'results.new', season.id.to_s, "0445-calendar_link-#{calendar.id}-150100.sql")
      )
      content = File.read(result.sql_path)
      expect(content).to include('START TRANSACTION;').and include("`results_code`='150100'")
        .and include("WHERE `id`=#{calendar.id};").and include('COMMIT;')
    end

    it 'does not replace an existing FIN results_link with a non-FIN one' do
      calendar.update!(results_link: fin_url)
      link(results_link: 'https://nuoto.ficr.it/#/x')
      expect(calendar.reload.results_link).to eq(fin_url)
    end

    it 'sets a blank manifest_link when given' do
      link(manifest_link: 'https://www.federnuoto.it/component/solrconnect/download.html?file=abc')
      expect(calendar.reload.manifest_link).to include('solrconnect')
    end
  end

  context 'when the calendar belongs to another season' do
    let(:other_calendar) { FactoryBot.create(:calendar) }

    it 'fails without changes nor files' do
      result = described_class.new(season:, calendar_id: other_calendar.id, fin_event_id: '150100', data_root:).call
      expect(result).not_to be_success
      expect(result.error).to match(/season/i)
      expect(result.sql_path).to be_nil
      expect(other_calendar.reload.results_code).to be_nil
      expect(Dir.glob(File.join(data_root, '**', '*.sql'))).to be_empty
    end
  end

  context 'when another season calendar already has the same results_code' do
    before(:each) { FactoryBot.create(:calendar, season:, meeting: FactoryBot.create(:meeting, season:), results_code: '150100') }

    it 'fails without changes nor files' do
      result = link
      expect(result).not_to be_success
      expect(result.error).to include('150100')
      expect(calendar.reload.results_code).to be_nil
      expect(Dir.glob(File.join(data_root, '**', '*.sql'))).to be_empty
    end
  end

  context 'when the calendar already has a different results_code' do
    before(:each) { calendar.update!(results_code: '150555') }

    it 'fails without changes nor files' do
      result = link
      expect(result).not_to be_success
      expect(result.error).to include('150555')
      expect(calendar.reload.results_code).to eq('150555')
      expect(Dir.glob(File.join(data_root, '**', '*.sql'))).to be_empty
    end
  end

  context 'with an invalid FIN event id' do
    it 'fails' do
      result = described_class.new(season:, calendar_id: calendar.id, fin_event_id: 'abc', data_root:).call
      expect(result).not_to be_success
    end
  end

  context 'when the calendar is already linked to the same FIN id' do
    before(:each) { calendar.update!(results_code: '150100') }

    it 'succeeds without writing a file' do
      result = link
      expect(result).to be_success
      expect(result.sql_path).to be_nil
    end
  end

  describe 'ops event log' do
    it 'records one board.calendar_linked event when the calendar changes' do
      result = nil
      expect { result = link(results_link: fin_url) }.to change(Ops::Event, :count).by(1)
      event = Ops::Event.last
      expect(event).to have_attributes(kind: 'board.calendar_linked', level: 'success', actor: 'operator', season_id: season.id,
                                       subject_type: 'fin_event', subject_key: '150100')
      expect(event.data).to eq('calendar_id' => calendar.id, 'changes' => %w[results_code results_link],
                               'sql_filename' => File.basename(result.sql_path.to_s))
    end

    it 'records nothing when nothing changes or the link fails' do
      calendar.update!(results_code: '150100')
      expect { link }.not_to change(Ops::Event, :count)
      expect { described_class.new(season:, calendar_id: calendar.id, fin_event_id: 'abc', data_root:).call }
        .not_to change(Ops::Event, :count)
    end

    it 'links all the same when the event write fails' do
      allow(Ops::Event).to receive(:create!).and_raise(ArgumentError, 'kaboom')
      expect(link).to be_success
      expect(calendar.reload.results_code).to eq('150100')
    end
  end
end
