# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'DataFix::SessionsListController' do
  include AdminSignInHelpers

  let(:source_a) { 'crawler/data/results.new/9997/list-a-lt4.json' }
  let(:source_b) { 'crawler/data/results.new/9997/list-b-lt4.json' }

  before(:each) do
    sign_in_admin(prepare_admin_user)
    GogglesDb::DataImportMeetingIndividualResult.where('phase_file_path LIKE ?', '%9997%').delete_all
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'list-a', phase_file_path: source_a, rank: 1)
    GogglesDb::DataImportMeetingIndividualResult.create!(import_key: 'list-b', phase_file_path: source_b, rank: 1)
  end

  after(:each) { GogglesDb::DataImportMeetingIndividualResult.where('phase_file_path LIKE ?', '%9997%').delete_all }

  describe 'GET /data_fix/sessions' do
    it 'lists the sources with staging rows and a purge button' do
      get data_fix_sessions_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('list-a-lt4.json', 'list-b-lt4.json')
      expect(response.body).to include(data_fix_sessions_purge_path(source_path: source_a).gsub('&', '&amp;'))
    end
  end

  describe 'DELETE /data_fix/sessions/purge' do
    it 'purges only the given source and records the event' do
      expect { delete data_fix_sessions_purge_path, params: { source_path: source_a } }.to change(Ops::Event, :count).by(1)

      expect(response).to redirect_to(data_fix_sessions_path)
      expect(GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_a)).to be_none
      expect(GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_b).count).to eq(1)
    end

    it 'refuses an unknown source and deletes nothing' do
      delete data_fix_sessions_purge_path, params: { source_path: 'crawler/data/nope.json' }

      expect(response).to redirect_to(data_fix_sessions_path)
      expect(flash[:warning]).to be_present
      expect(GogglesDb::DataImportMeetingIndividualResult.where('phase_file_path LIKE ?', '%9997%').count).to eq(2)
    end
  end
end
