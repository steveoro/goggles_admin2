# frozen_string_literal: true

require 'rails_helper'

# Per-source purge of the Data-Fix import staging rows (moved here from the removed DataFixController#purge,
# whose "Clean slate" full wipe is gone: DataFix::StagingPurger.purge_all! is kept for phase 14's restore steps).
RSpec.describe DataFix::SessionsListController do
  include AdminSignInHelpers

  describe 'DELETE /data_fix/sessions/purge' do
    let(:source_a) { 'crawler/data/results.new/9999/purge-a-lt4.json' }
    let(:source_b) { 'crawler/data/results.new/9999/purge-b-lt4.json' }
    let(:tables) do
      [
        GogglesDb::DataImportLap, GogglesDb::DataImportRelayLap, GogglesDb::DataImportMeetingRelaySwimmer,
        GogglesDb::DataImportMeetingRelayResult, GogglesDb::DataImportMeetingIndividualResult
      ]
    end

    def create_rows_for(path, tag)
      GogglesDb::DataImportMeetingIndividualResult.create!(import_key: "#{tag}-mir", phase_file_path: path, rank: 1)
      GogglesDb::DataImportLap.create!(import_key: "#{tag}-lap", parent_import_key: "#{tag}-mir", phase_file_path: path,
                                       length_in_meters: 50)
      GogglesDb::DataImportMeetingRelayResult.create!(import_key: "#{tag}-mrr", phase_file_path: path, rank: 1)
      GogglesDb::DataImportMeetingRelaySwimmer.create!(import_key: "#{tag}-mrs", parent_import_key: "#{tag}-mrr",
                                                       phase_file_path: path, relay_order: 1)
      GogglesDb::DataImportRelayLap.create!(import_key: "#{tag}-rlap", parent_import_key: "#{tag}-mrr",
                                            phase_file_path: path, length_in_meters: 50)
    end

    before(:each) do
      sign_in_admin(prepare_admin_user)
      tables.each(&:delete_all)
      create_rows_for(source_a, 'purge-a')
      create_rows_for(source_b, 'purge-b')
    end

    after(:each) { tables.each(&:delete_all) }

    context 'with a known source_path' do
      it 'deletes only the rows of that source in all five tables' do
        delete data_fix_sessions_purge_path, params: { source_path: source_a }

        expect(response).to redirect_to(data_fix_sessions_path)
        expect(flash[:notice]).to eq(I18n.t('data_import.data_fix.discard_source_done', total: 5, source: source_a))
        tables.each do |table|
          expect(table.where(phase_file_path: source_a).count).to eq(0)
          expect(table.where(phase_file_path: source_b).count).to eq(1)
        end
      end

      it 'purges a source with relay rows only' do
        GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_a).delete_all
        GogglesDb::DataImportLap.where(phase_file_path: source_a).delete_all

        delete data_fix_sessions_purge_path, params: { source_path: source_a }

        expect(flash[:notice]).to be_present
        tables.each { |table| expect(table.where(phase_file_path: source_a).count).to eq(0) }
      end
    end

    describe 'ops event log' do
      it 'records one scoped datafix.purged event per purge' do
        expect { delete data_fix_sessions_purge_path, params: { source_path: source_a } }.to change(Ops::Event, :count).by(1)

        event = Ops::Event.of_kind('datafix.purged').recent.first
        expect(event.actor).to eq('operator')
        expect(event.subject_type).to eq('source')
        expect(event.subject_key).to eq(source_a)
        expect(event.data['scope']).to eq(source_a)
        expect(event.data['deleted'].values.sum).to eq(5)
      end

      it 'records nothing for a refused purge' do
        expect { delete data_fix_sessions_purge_path, params: { source_path: 'crawler/data/nope.json' } }
          .not_to change(Ops::Event, :count)
      end

      it 'does not change the response when the ops write fails' do
        allow(Ops).to receive(:record_event!).and_raise(StandardError, 'ops down')

        delete data_fix_sessions_purge_path, params: { source_path: source_a }

        expect(response).to redirect_to(data_fix_sessions_path)
        expect(flash[:notice]).to be_present
        expect(flash[:error]).to be_blank
        tables.each { |table| expect(table.where(phase_file_path: source_a).count).to eq(0) }
      end
    end

    context 'with a blank, missing or unknown source_path' do
      it 'refuses politely and deletes nothing' do
        [{ source_path: '' }, {}, { source_path: 'crawler/data/nope.json' }].each do |params|
          delete(data_fix_sessions_purge_path, params:)

          expect(response).to redirect_to(data_fix_sessions_path)
          expect(flash[:warning]).to be_present
          tables.each { |table| expect(table.count).to eq(2) }
        end
      end
    end

    it 'has no global "Clean slate" route any more' do
      expect { delete('/data_fix/purge') }.to raise_error(ActionController::RoutingError)
    end
  end
end
