# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Drift::IndicatorComponent, type: :component do
  let(:api_url) { 'http://localhost:8081' }

  before(:each) do
    # (renders from the stored row only: the API is unreachable and never called)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(APIProxy).to receive(:ping).and_raise('no API call expected')
  end

  after(:each) { Ops::Database.reset_state! }

  it 'renders the last stored verdict of the API as a pill linking to /db_sync' do
    FactoryBot.create(:ops_db_fingerprint, :red, api_base_url: api_url)
    render_inline(described_class.new(api_url:))
    pill = page.find('a#drift-indicator')
    expect(pill[:href]).to eq('/db_sync')
    expect(pill[:'data-drift-verdict']).to eq('red')
    expect(pill[:class]).to include('text-bg-danger')
    expect(pill.text).to include(I18n.t('db_sync.indicator.label', verdict: I18n.t('db_sync.verdicts.red')))
    expect(pill[:title]).to include('laps')
  end

  it 'lists the reasons with details: true and renders a plain pill with link: false' do
    row = FactoryBot.create(:ops_db_fingerprint, :amber, api_base_url: api_url)
    render_inline(described_class.new(fingerprint: row, details: true, link: false))
    expect(page).to have_css('span#drift-indicator.text-bg-warning')
    expect(page).to have_css('#drift-indicator-reasons li', text: Drift::ReasonText.call(row.reasons.first))
  end

  it "reads a stale green check as amber and renders 'unknown' without any check" do
    FactoryBot.create(:ops_db_fingerprint, api_base_url: api_url, taken_at: 3.hours.ago)
    render_inline(described_class.new(api_url:))
    expect(page).to have_css('#drift-indicator[data-drift-verdict="amber"]')

    render_inline(described_class.new(api_url: 'http://never-checked:1'))
    expect(page).to have_css('#drift-indicator[data-drift-verdict="unknown"].text-bg-secondary')
  end

  it "renders 'unknown' with the ops DB missing" do
    allow(Ops::Database).to receive(:state).and_return(:missing)
    render_inline(described_class.new(api_url:))
    expect(page).to have_css('#drift-indicator[data-drift-verdict="unknown"]')
  end
end
