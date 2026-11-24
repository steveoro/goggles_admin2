# frozen_string_literal: true

# = API grid pages: the API error answered in place (phase 15, APIGridIndex + Grid::APIErrorComponent)
#
# REQUIRES/ASSUMES (let):
# - index_path: the index page path (e.g. api_teams_path);
# - api_params: the exact :params of the index APIProxy.call, as stubbed by the success examples of the same spec.
#
# == Usage:
#   it_behaves_like('an API grid index showing an API error in place', 'teams') do
#     let(:index_path) { api_teams_path }
#     let(:api_params) { { name: anything, page: anything, per_page: anything } }
#   end
#
shared_examples_for 'an API grid index showing an API error in place' do |api_url|
  include AdminSignInHelpers

  let(:error_admin_user) { prepare_admin_user }
  let(:error_result) do
    APIProxy::Result.new(instance_double(RestClient::Response, code: 503, body: 'Service Unavailable', headers: {}))
  end

  before(:each) do
    sign_in_admin(error_admin_user)
    allow(APIProxy).to receive(:call).with(method: :get, url: api_url, jwt: error_admin_user.jwt, params: api_params)
                                     .and_return(error_result)
    get(index_path)
  end

  it 'renders the page with the API error box (code, detail, Retry) and status 200 instead of redirecting' do
    expect(response).to have_http_status(:ok)
    box = response.parsed_body.at_css("##{Grid::APIErrorComponent::DOM_ID}")
    expect(box).to be_present
    expect(box['data-api-error-code']).to eq('503')
    expect(box.at_css('#grid-api-error-detail').text).to include('Service Unavailable')
    expect(box.at_css('#grid-api-error-retry')['href']).to eq(index_path)
    expect(response.parsed_body.at_css('table.datagrid-table')).to be_nil
    expect(flash[:error]).to be_nil
  end
end
