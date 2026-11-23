# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::StatusPillComponent, type: :component do
  let(:checked_at) { Time.zone.parse('2026-11-23 10:15:00') }

  def result(level, action: nil)
    SystemStatus::Result.new(key: :api, label: 'API', level:, detail: 'Some detail', checked_at:, action:)
  end

  {
    ok: 'text-bg-success', warn: 'text-bg-warning', error: 'text-bg-danger', unknown: 'text-bg-secondary'
  }.each do |level, css|
    it "renders a #{level} pill as #{css}" do
      pill = render_inline(described_class.new(result: result(level))).at_css('#status-pill-api')
      expect(pill['class']).to include('badge', css)
      expect(pill['data-status-level']).to eq(level.to_s)
      expect(pill.text.strip).to eq('API')
    end
  end

  it 'puts the detail and the "as of" time in the tooltip' do
    pill = render_inline(described_class.new(result: result(:ok))).at_css('#status-pill-api')
    expect(pill['data-bs-toggle']).to eq('tooltip')
    expect(pill['data-bs-title']).to include('Some detail', I18n.t('shell.status.as_of', time: I18n.l(checked_at.localtime, format: :short)))
  end

  it 'links to the action path (breaking out of the frame)' do
    pill = render_inline(described_class.new(result: result(:error, action: { label: 'Open Settings', path: '/settings' })))
           .at_css('a#status-pill-api')
    expect(pill['href']).to eq('/settings')
    expect(pill['data-turbo-frame']).to eq('_top')
    expect(pill['data-bs-title']).to include('Open Settings')
  end

  it 'refuses an unsupported level' do
    expect { result(:bogus) }.to raise_error(ArgumentError)
  end
end
