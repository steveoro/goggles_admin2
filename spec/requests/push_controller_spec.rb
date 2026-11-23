# frozen_string_literal: true

require 'rails_helper'

# The Push page was replaced by the SQL Outbox (phase 07): only the redirect is left.
RSpec.describe PushController do
  describe 'GET /push/index' do
    it 'is a redirect to the login path for an unlogged user' do
      get '/push/index'
      expect(response).to redirect_to(new_user_session_path)
    end

    context 'with a logged-in admin' do
      include AdminSignInHelpers

      before(:each) { sign_in_admin(prepare_admin_user) }

      it 'redirects to the Outbox, dropping the old folder params' do
        get '/push/index', params: { parent_folder: 'results.new', curr_dir: 'data/results.new/242' }
        expect(response).to redirect_to(outbox_path)
        expect(response).to have_http_status(:moved_permanently)
      end
    end
  end

  it 'has no upload route any more' do
    expect { Rails.application.routes.recognize_path('/push/upload', method: :post) }.to raise_error(ActionController::RoutingError)
  end
end
