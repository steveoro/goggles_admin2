# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'DataFixes', type: :request do
  describe 'GET /index' do
    it 'returns http success' do
      get '/data_fix/index'
      expect(response).to have_http_status(:success)
    end
  end
end
