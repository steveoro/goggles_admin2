# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfController do
  describe "GET /extract_txt" do
    it "returns http success" do
      get "/pdf/extract_txt"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /export_json" do
    it "returns http success" do
      get "/pdf/export_json"
      expect(response).to have_http_status(:success)
    end
  end
end
