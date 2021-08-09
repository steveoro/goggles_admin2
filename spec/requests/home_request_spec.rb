# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Homes', type: :request do
  include ActiveJob::TestHelper

  let(:fixture_user) { GogglesDb::User.first(50).sample }
  before(:each) { expect(fixture_user).to be_a(GogglesDb::User).and be_valid }

  describe 'GET /index' do
    context 'for an unlogged user' do
      it 'is a redirect to the login path' do
        get(home_index_path)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'for a logged-in user' do
      before(:each) { sign_in(fixture_user) }
      it 'returns http success' do
        get(home_index_path)
        expect(response).to have_http_status(:success)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
