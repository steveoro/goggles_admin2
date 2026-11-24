# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::APIErrorComponent, type: :component do
  include AdminSignInHelpers

  let(:error_result) do
    APIProxy::Result.new(instance_double(RestClient::Response, code: 500, body: 'Internal Server Error', headers: {}))
  end

  describe '.error_for' do
    it 'takes the code and the error detail of an API result' do
      error = described_class.error_for(error_result)
      expect(error).to have_attributes(code: 500, detail: 'Internal Server Error', unreachable?: false)
    end

    it 'flags an unreachable API server' do
      error = described_class.error_for(unreachable_api_result)
      expect(error.code).to eq(503)
      expect(error).to be_unreachable
      expect(error.detail).to include('API unreachable')
    end

    it 'prefers the X-Error-Detail header' do
      result = APIProxy::Result.new(instance_double(RestClient::Response, code: 422, body: '{"error":"body detail"}',
                                                                          headers: { x_error_detail: 'header detail' }))
      expect(described_class.error_for(result).detail).to eq('header detail')
    end
  end

  it 'renders nothing without an error' do
    expect(render_inline(described_class.new(error: nil)).to_html).to be_empty
  end

  context 'with an API error answer' do
    subject(:box) do
      with_request_url('/api_teams?teams_grid%5Bname%5D=x') do
        render_inline(described_class.new(error: described_class.error_for(error_result)))
      end.at_css("##{described_class::DOM_ID}")
    end

    it 'renders a native alert with the code, the detail and a Retry link to the same URL' do
      expect(box['class']).to include('alert', 'alert-danger')
      expect(box['role']).to eq('alert')
      expect(box['data-api-error-code']).to eq('500')
      expect(box.at_css('#grid-api-error-title').text).to include(I18n.t('datagrid.api_error.title', code: 500))
      expect(box.at_css('#grid-api-error-detail').text).to eq('Internal Server Error')
      expect(box.at_css('a#grid-api-error-retry')['href']).to eq('/api_teams?teams_grid%5Bname%5D=x')
      expect(box.at_css('#grid-api-error-settings')).to be_nil
    end
  end

  it 'links the API URL in Settings for an unreachable server, with the given Retry path' do
    html = render_inline(described_class.new(error: described_class.error_for(unreachable_api_result), retry_path: '/api_swimmers'))
    expect(html.at_css('#grid-api-error-title').text).to include(I18n.t('datagrid.api_error.unreachable_title'))
    expect(html.at_css('a#grid-api-error-settings')['href']).to eq('/settings')
    expect(html.at_css('a#grid-api-error-retry')['href']).to eq('/api_swimmers')
  end

  it 'truncates a long error detail (e.g. a whole HTML error page)' do
    error = described_class::Error.new(code: 502, detail: "<html>#{'x' * 2000}</html>", unreachable: false)
    detail = render_inline(described_class.new(error:, retry_path: '/')).at_css('#grid-api-error-detail').text
    expect(detail.length).to eq(described_class::DETAIL_MAX)
    expect(detail).to end_with('...')
  end
end
