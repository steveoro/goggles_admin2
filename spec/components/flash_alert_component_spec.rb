# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FlashAlertComponent, type: :component do
  subject(:toast) { render_inline(described_class.new(**params)).at_css('.toast') }

  let(:params) { { symbol: :notice, body: 'All done', title: 'Title' } }

  it 'renders a toast bound to the toast controller, keeping the flash-alert marker' do
    expect(toast[:class]).to include('flash-alert')
    expect(toast[:role]).to eq('alert')
    expect(toast['data-controller']).to eq('toast')
    expect(toast.text).to include('All done', 'Title')
  end

  it 'has a toast close button & no sticky marker by default' do
    expect(toast.at_css('.btn-close')['data-bs-dismiss']).to eq('toast')
    expect(toast[:class]).not_to include('flash-sticky')
  end

  it 'auto-hides regular toasts' do
    expect(toast['data-toast-autohide-value']).to eq('true')
  end

  { error: 'text-bg-danger', warning: 'text-bg-warning', alert: 'text-bg-warning',
    info: 'text-bg-info', notice: 'text-bg-secondary' }.each do |symbol, css_class|
    context "with the :#{symbol} symbol" do
      let(:params) { { symbol:, body: 'Message' } }

      it "uses #{css_class}" do
        expect(toast[:class]).to include(css_class)
      end
    end
  end

  context 'with the :error symbol' do
    let(:params) { { symbol: :error, body: 'Boom' } }

    it 'never auto-hides' do
      expect(toast['data-toast-autohide-value']).to eq('false')
    end
  end

  context 'when sticky' do
    let(:params) { { symbol: :info, body: 'Stay', sticky: true } }

    it 'adds the flash-sticky marker and never auto-hides' do
      expect(toast[:class]).to include('flash-alert', 'flash-sticky')
      expect(toast['data-toast-autohide-value']).to eq('false')
    end
  end

  context 'with an unsupported symbol or an empty body' do
    it 'renders nothing' do
      expect(render_inline(described_class.new(symbol: :bogus, body: 'x')).to_html).to be_blank
      expect(render_inline(described_class.new(symbol: :info, body: '')).to_html).to be_blank
    end
  end
end
