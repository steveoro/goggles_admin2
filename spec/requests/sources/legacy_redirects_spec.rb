# frozen_string_literal: true

require 'rails_helper'

# Phase 15: the Pull, PDF and file-list GET URLs redirect to the Sources area for one release; their POST, PUT and
# DELETE routes are gone.
RSpec.describe 'Sources legacy redirects' do
  include AdminSignInHelpers

  before(:each) { sign_in_admin(prepare_admin_user) }

  {
    '/pull/index' => '/sources/crawler',
    '/pull/index?sub_menu_type=Riepilogo+Eventi' => '/sources/crawler?sub_menu_type=Riepilogo+Eventi',
    '/pull/calendar_files' => '/sources/calendars',
    '/pull/result_files' => '/sources/results',
    '/pull/result_files?filter=*.pdf&parent_folder=pdfs' => '/sources/pdfs',
    '/pull/calendar_meetings?file_path=%2Fx%2Fcal.csv' => '/sources/calendars/meetings?path=%2Fx%2Fcal.csv',
    '/pull/edit_name?file_path=%2Fx%2Fa.json' => '/sources/files/rename?path=%2Fx%2Fa.json',
    '/pull/edit_file?file_path=%2Fx%2Fa.json' => '/sources/files/edit?path=%2Fx%2Fa.json',
    '/pdf/extract_txt?file_path=%2Fx%2Fp.pdf' => '/sources/pdfs/show?path=%2Fx%2Fp.pdf',
    '/sources' => '/sources/results'
  }.each do |old_path, new_path|
    it "redirects GET #{old_path} to #{new_path}" do
      get(old_path)
      expect(response).to have_http_status(:moved_permanently)
      expect(response.location).to end_with(new_path)
    end
  end

  it 'has no Pull, PDF or file-list write route left' do
    [%w[POST /pull/run_crawler_api], %w[POST /pull/start_crawler], %w[PUT /pull/file_rename], %w[PUT /pull/file_edit],
     %w[DELETE /pull/file_delete], %w[POST /pull/process_calendar_file], %w[POST /pull/process_selected_meetings],
     %w[POST /pull/extract_manifests], %w[GET /pull/extraction_status], %w[PUT /pull/result_files], %w[PUT /pdf/scan],
     %w[PUT /pdf/log_contents]].each do |verb, path|
      expect { Rails.application.routes.recognize_path(path, method: verb) }.to raise_error(ActionController::RoutingError), "#{verb} #{path}"
    end
    expect(Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }.grep(/\A(pull|pdf|file_list)\z/)).to be_empty
  end

  it 'is a redirect to the login path for an unlogged user (once on the new page)' do
    sign_out(:user)
    get('/sources/crawler')
    expect(response).to redirect_to(new_user_session_path)
  end
end
