# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::Calendar do
  subject(:committer) { described_class.new(stats:, logger:, sql_log:) }

  let(:stats) { { calendars_created: 0, calendars_updated: 0, errors: [] } }
  let(:logger) { instance_double(Import::PhaseCommitLogger, log_success: nil, log_validation_error: nil) }
  let(:sql_log) { [] }
  let(:meeting) { FactoryBot.create(:meeting) }

  let(:fin_id) { '150091' }
  let(:fin_results_url) do
    "https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/#{fin_id}:distanze-speciali-campania-2026.html"
  end
  let(:fin_manifest_url) do
    encoded = Base64.strict_encode64("/var/www/fin_files/eventi/0000#{fin_id}.pdf")
    "https://www.federnuoto.it/component/solrconnect/download.html?file=#{CGI.escape(encoded)}"
  end
  let(:ficr_url) { 'https://nuoto.ficr.it/#/NUO/tempi/25/2026/29/27/AAX/1' }

  let(:base_hash) do
    {
      'meeting_id' => meeting.id,
      'dateYear1' => meeting.header_date.year.to_s,
      'dateMonth1' => meeting.header_date.strftime('%m'),
      'venue1' => 'Piscina Comunale'
    }
  end

  # Creates a calendar row bound to the same season of the meeting.
  def create_calendar(**attrs)
    FactoryBot.create(:calendar, { meeting:, season: meeting.season }.merge(attrs))
  end

  describe '#commit' do
    context 'when no calendar row exists yet' do
      it 'sets results_code from a FIN results URL' do
        id = committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        row = GogglesDb::Calendar.find(id)
        expect(row.results_code).to eq(fin_id)
        expect(row.results_link).to eq(fin_results_url)
        expect(stats[:calendars_created]).to eq(1)
        expect(sql_log.last).to include('INSERT INTO `calendars`').and include("'#{fin_id}'")
      end

      it 'sets results_code from a FIN manifest URL when no results URL carries it' do
        id = committer.commit(base_hash.merge('meetingURL' => ficr_url, 'manifestURL' => fin_manifest_url))

        row = GogglesDb::Calendar.find(id)
        expect(row.results_code).to eq(fin_id)
        expect(row.manifest_link).to eq(fin_manifest_url)
      end

      it 'leaves results_code blank when no URL carries a FIN id' do
        id = committer.commit(base_hash.merge('meetingURL' => ficr_url))

        expect(GogglesDb::Calendar.find(id).results_code).to be_nil
      end
    end

    context 'when a calendar row with the same FIN id exists' do
      it 'updates the row matched by results_code when it belongs to the same meeting' do
        by_fin_id = create_calendar(meeting_code: 'other-code', results_code: fin_id)

        id = committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        expect(id).to eq(by_fin_id.id)
        expect(stats[:calendars_created]).to eq(0)
      end

      it 'claims the row matched by results_code when it is not linked to any meeting, even when another row matches the meeting code' do
        by_code = create_calendar
        by_fin_id = create_calendar(meeting_code: 'unassigned-code', meeting_name: 'Unassigned', results_code: fin_id)
        by_fin_id.update_columns(meeting_id: nil) # rubocop:disable Rails/SkipsModelValidations

        id = committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        expect(id).to eq(by_fin_id.id)
        expect(by_fin_id.reload.meeting_id).to eq(meeting.id)
        expect(by_code.reload.results_code).to be_nil
        expect(stats[:calendars_updated]).to eq(1)
        expect(stats[:calendars_created]).to eq(0)
      end

      context 'when the row matched by results_code belongs to another meeting' do
        let(:other_meeting) { FactoryBot.create(:meeting, season: meeting.season) }
        let!(:by_fin_id) { create_calendar(meeting: other_meeting, meeting_code: other_meeting.code, results_code: fin_id) }
        let!(:by_code) { create_calendar }
        let(:logger) do
          instance_double(Import::PhaseCommitLogger, log_success: nil, log_validation_error: nil, log_error: nil)
        end

        it 'raises a clear error naming the calendar, the FIN event and both meetings, writing nothing' do
          expect { committer.commit(base_hash.merge('meetingURL' => fin_results_url)) }
            .to raise_error(StandardError, /FIN event #{fin_id} is already linked to meeting #{other_meeting.id} through calendar #{by_fin_id.id}/)

          expect(stats[:errors].first).to include("calendar #{by_fin_id.id}", fin_id, other_meeting.id.to_s, meeting.id.to_s)
          expect(by_fin_id.reload.meeting_id).to eq(other_meeting.id)
          expect(by_code.reload.results_code).to be_nil
          expect(sql_log).to be_empty
          expect(stats[:calendars_updated] + stats[:calendars_created]).to eq(0)
        end

        it 'does not raise from #prepare_model' do
          expect { committer.prepare_model(base_hash.merge('meetingURL' => fin_results_url), meeting:) }.not_to raise_error
        end
      end

      it 'ignores rows with the same FIN id belonging to another season' do
        other_season_meeting = FactoryBot.create(:meeting)
        FactoryBot.create(:calendar, meeting: other_season_meeting, season: other_season_meeting.season,
                                     results_code: fin_id)
        by_code = create_calendar

        id = committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        expect(id).to eq(by_code.id)
        expect(by_code.reload.results_code).to eq(fin_id)
      end
    end

    context 'when the existing row links to a FIN results page' do
      let!(:existing) { create_calendar(results_link: fin_results_url, results_code: fin_id) }

      it 'does not overwrite the FIN link with a non-FIN (FICR) URL' do
        committer.commit(base_hash.merge('meetingURL' => ficr_url))

        expect(existing.reload.results_link).to eq(fin_results_url)
        expect(sql_log.join).not_to include(ficr_url)
      end

      it 'does not blank out the FIN link, results_code or manifest_link' do
        existing.update!(manifest_link: fin_manifest_url)

        committer.commit(base_hash.merge('meetingURL' => '', 'manifestURL' => nil))

        existing.reload
        expect(existing.results_link).to eq(fin_results_url)
        expect(existing.results_code).to eq(fin_id)
        expect(existing.manifest_link).to eq(fin_manifest_url)
      end
    end

    context 'when the existing row links to a non-FIN results page' do
      let!(:existing) { create_calendar(results_link: ficr_url) }

      it 'replaces the link with the FIN one and sets results_code' do
        committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        existing.reload
        expect(existing.results_link).to eq(fin_results_url)
        expect(existing.results_code).to eq(fin_id)
        expect(sql_log.last).to include('UPDATE `calendars`').and include("`results_code`='#{fin_id}'")
      end
    end

    context 'when the existing row already has a different FIN id' do
      let!(:existing) { create_calendar(results_code: '149999') }

      it 'keeps the stored results_code' do
        committer.commit(base_hash.merge('meetingURL' => fin_results_url))

        expect(existing.reload.results_code).to eq('149999')
      end

      it 'keeps the stored results_link and manifest_link too' do
        existing.update!(results_link: ficr_url, manifest_link: 'https://example.com/old-manifest.pdf')

        committer.commit(base_hash.merge('meetingURL' => fin_results_url, 'manifestURL' => fin_manifest_url))

        existing.reload
        expect(existing.results_link).to eq(ficr_url)
        expect(existing.manifest_link).to eq('https://example.com/old-manifest.pdf')
      end
    end
  end

  describe '#prepare_model' do
    it 'includes results_code in the draft model' do
      model = committer.prepare_model(base_hash.merge('manifestURL' => fin_manifest_url), meeting:)

      expect(model).to be_a(GogglesDb::Calendar)
      expect(model.results_code).to eq(fin_id)
    end
  end
end
