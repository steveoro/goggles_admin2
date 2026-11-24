# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::FixButtonComponent, type: :component do
  let(:finding) do
    FactoryBot.create(:ops_health_finding, check_key: 'meetings.no_results.unflagged', payload: { 'cancel' => { 'meeting_id' => 7 } })
  end

  it 'renders one button per operation of the finding, opening the prefilled form' do
    render_inline(described_class.new(finding:))
    expect(page).to have_link(I18n.t('maintenance.operations.meeting_set_cancelled.fix_label'),
                              href: "/operations/meeting.set_cancelled/new?finding_id=#{finding.id}")
  end

  it 'renders compact icon buttons with the label as title' do
    render_inline(described_class.new(finding:, compact: true))
    link = page.find('a[data-operation-key="meeting.set_cancelled"]')
    expect(link[:class]).to include('btn-sm')
    expect(link[:title]).to eq(I18n.t('maintenance.operations.meeting_set_cancelled.fix_label'))
  end

  it 'renders an explicit operation with its params only (commit report, follow-ups)' do
    render_inline(described_class.new(operation_key: 'ranks.recompute', params: { 'meeting_id' => 9, 'other' => 1 }, origin: 'health'))
    expect(page).to have_link(href: '/operations/ranks.recompute/new?meeting_id=9&origin=health')
  end

  it 'renders nothing when no operation applies, for a resolved finding, or when the operations are disabled' do
    expect(render_inline(described_class.new(finding: FactoryBot.create(:ops_health_finding, check_key: 'season.setup'))).to_html).to be_blank
    finding.update!(status: 'resolved')
    expect(render_inline(described_class.new(finding:)).to_html).to be_blank
    finding.update!(status: 'open')
    Ops::Setting.store!(Maintenance::ENABLED_SETTING, false)
    expect(render_inline(described_class.new(finding:)).to_html).to be_blank
  end
end
