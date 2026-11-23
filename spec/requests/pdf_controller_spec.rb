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

    context 'with a logged-in user and a file name with spaces and quotes' do
      include AdminSignInHelpers

      let(:temp_dir) { Dir.mktmpdir }
      let(:pdf_path) { File.join(temp_dir, %(my "odd" file; touch pwned.pdf)) }
      let(:txt_path) { pdf_path.sub('.pdf', '.txt') }

      before(:each) do
        sign_in_admin(prepare_admin_user)
      end

      after(:each) { FileUtils.rm_rf(temp_dir) }

      it 'passes the file names to pdftotext as separate, unparsed arguments' do
        expect_any_instance_of(described_class).to receive(:system) do |_ctrl, *args| # rubocop:disable RSpec/AnyInstance
          expect(args).to eq(['pdftotext', '-layout', pdf_path, txt_path])
          File.write(txt_path, "page one\fpage two")
          true
        end

        get pdf_extract_txt_path(file_path: pdf_path)

        expect(response).to have_http_status(:ok)
        expect(File).not_to exist(File.join(temp_dir, 'pwned.pdf'))
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

  describe 'PUT /pdf/log_contents (turbo stream flash update)' do
    include AdminSignInHelpers

    let(:temp_dir) { Dir.mktmpdir }
    let(:txt_path) { File.join(temp_dir, 'sample.txt') }

    before(:each) do
      sign_in_admin(prepare_admin_user)
      File.write(txt_path.sub('.txt', '.log'), 'some log')
    end

    after(:each) { FileUtils.rm_rf(temp_dir) }

    it 'updates only the flash toasts container, leaving the sticky alerts alone' do
      put pdf_log_contents_path(file_path: txt_path), as: :turbo_stream

      expect(response).to have_http_status(:ok)
      streams = Nokogiri::HTML.fragment(response.body).css('turbo-stream')
      targets = streams.pluck('target')
      expect(targets).to include('flash-messages-container', 'log-result')
      expect(targets).not_to include('sticky-alerts', 'api-offline-banner')
      expect(response.body).not_to include('sticky-alerts')
    end
  end
end
