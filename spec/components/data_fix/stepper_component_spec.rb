# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::StepperComponent, type: :component do
  def verdict(phase, status, **options)
    DataFix::Verdict.build(phase:, status:, **options)
  end

  def summary(verdicts, source_changed: false, source_details: {})
    DataFix::Pipeline::Summary.new(verdicts:, stage: 'needs_review', review_phase: 2, source_changed:, source_details:,
                                   result_free: false, source_kind: 'results')
  end

  let(:verdicts) do
    {
      1 => verdict(1, 'clean'), 2 => verdict(2, 'review', issues: [{ 'code' => 'teams_review', 'level' => 'review', 'count' => 3 }]),
      3 => verdict(3, 'blocked', issues: [{ 'code' => 'new_swimmer_incomplete', 'level' => 'blocked', 'count' => 1 }]),
      4 => verdict(4, 'clean', edited: true, adopted: true),
      5 => verdict(5, 'stale', stale_reasons: [{ 'upstream' => 4, 'what' => 'events', 'key' => 'p4' }],
                               issues: [{ 'code' => 'stale', 'level' => 'stale', 'count' => 1 }])
    }
  end

  it 'renders the five step tabs (one .nav-link each) with their verdict badges and issue counts' do
    with_request_url('/data_fix/review_teams') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 2, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('ul.nav-tabs .nav-link', count: 5)
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 2 • Teams')
    expect(page).to have_css('.nav-link [data-verdict="review"]', text: '3')
    expect(page).to have_css('.nav-link [data-verdict="blocked"]', text: '1')
    expect(page).to have_css('.nav-link [data-verdict="stale"]')
    expect(page).to have_link(href: %r{/data_fix/review_teams\?.*rescan=1})
  end

  it 'shows the stale banner on a stale active step and the adopted note on a pre-existing one' do
    with_request_url('/data_fix/review_results') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 5, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('#data-fix-step-stale', text: I18n.t('data_fix.stepper.inputs.events'))

    with_request_url('/data_fix/review_events') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 4, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('#data-fix-step-adopted')
  end

  it 'offers "Rebuild (discard edits)" when the source changed under the edits' do
    with_request_url('/data_fix/review_swimmers') do
      render_inline(described_class.new(summary: summary(verdicts, source_changed: true, source_details: { 'phases' => [3, 4, 5] }),
                                        active_step: 3, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('#data-fix-source-changed', text: '3, 4, 5')
    expect(page).to have_css("form[action='/data_fix/discard_phase_edits'] button", text: I18n.t('data_fix.stepper.discard_edits'))
  end

  it 'renders plain tabs without a summary' do
    with_request_url('/data_fix/review_sessions') do
      render_inline(described_class.new(summary: nil, active_step: 1, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('ul.nav-tabs .nav-link', count: 5)
    expect(page).to have_no_css('[data-verdict]')
  end
end
