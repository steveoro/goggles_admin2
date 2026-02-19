# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfController do
  describe 'GET /extract_txt' do
    context 'with an unlogged user' do
      it 'is a redirect to the login path' do
        get pdf_extract_txt_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'with a logged-in user but no file_path' do
      include AdminSignInHelpers
      before(:each) do
        admin_user = prepare_admin_user
        sign_in_admin(admin_user)
      end

      it 'redirects with a flash warning when file_path is missing' do
        get pdf_extract_txt_path
        expect(response).to have_http_status(:redirect)
        expect(flash[:warning]).to be_present
      end
    end
  end
end
