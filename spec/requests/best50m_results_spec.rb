require 'rails_helper'

RSpec.describe 'Best50mResults', type: :request do
  describe 'GET /index' do
    it 'returns http success' do
      get '/best50m_results/index'
      expect(response).to have_http_status(:success)
    end
  end
end
