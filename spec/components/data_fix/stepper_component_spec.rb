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

  it 'offers the active step rebuild in its menu, naming the edits it discards' do
    edited = verdicts.merge(2 => verdict(2, 'review', edited: true))
    marker = { 'at' => '2026-11-24T10:12:00Z', 'actions' => %w[update_phase2_team update_phase2_team delete_team] }
    with_request_url('/data_fix/review_teams') do
      render_inline(described_class.new(summary: summary(edited), active_step: 2, file_path: '/x/242/a-lt4.json', edit_marker: marker))
    end
    item = page.find('.nav-link.active .dropdown-menu a#data-fix-step-rescan', visible: :all)
    expect(item[:href]).to include('rescan=1')
    # (Turbo 8 asks the confirmation only for a link it turns into a form: a plain GET link would rebuild at once)
    expect(item['data-turbo-method']).to eq('get')
    expect(item['data-turbo-confirm']).to include("#{I18n.t('data_fix.stepper.edit_actions.update_phase2_team')} ×2")
    expect(item['data-turbo-confirm']).to include(I18n.t('data_fix.stepper.edit_actions.delete_team'))
    expect(page).to have_css('.nav-link.active button.dropdown-toggle[data-bs-toggle="dropdown"]')
    expect(page).to have_css('#data-fix-step-edited', text: I18n.t('data_fix.stepper.edit_actions.delete_team'))
  end

  it 'rebuilds a stale step with a POST (force and a confirmation only for an edited phase)' do
    with_request_url('/data_fix/review_results') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 5, file_path: '/x/242/a-lt4.json'))
    end
    form = page.find("#data-fix-step-stale form[action='/data_fix/rebuild_phase']")
    expect(form).to have_css('input[name="phase"][value="5"]', visible: :all)
    expect(form).to have_no_field('force', type: :hidden)
    expect(form).to have_no_css('[data-turbo-confirm]')

    stale_edited = verdicts.merge(5 => verdict(5, 'stale', edited: true, stale_reasons: [{ 'upstream' => 4, 'what' => 'events', 'key' => 'p4' }]))
    with_request_url('/data_fix/review_results') do
      render_inline(described_class.new(summary: summary(stale_edited), active_step: 5, file_path: '/x/242/a-lt4.json'))
    end
    form = page.find("#data-fix-step-stale form[action='/data_fix/rebuild_phase']")
    expect(form).to have_field('force', type: :hidden, with: '1')
    expect(form).to have_css('button[data-turbo-confirm]')
  end

  it 'shows the "being prepared" state with the prepare run progress, and the crawl retry banner' do
    run = Ops::PipelineRun.new(kind: 'prepare', phase: 3, message: 'matching swimmers', progress: 12, total: 40)
    with_request_url('/data_fix/review_swimmers') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 3, file_path: '/x/242/a-lt4.json',
                                        being_prepared: run, retry_needed: true))
    end
    expect(page).to have_css('ul.data-fix-stepper[data-data-fix-stepper="preparing"]')
    expect(page).to have_css('#data-fix-being-prepared-progress', text: 'matching swimmers (12/40)')
    expect(page).to have_css('#data-fix-being-prepared progress[value="30"]')
    expect(page).to have_css('#data-fix-retry-needed')
  end

  it 'collapses the inactive steps to their number below the md breakpoint' do
    with_request_url('/data_fix/review_teams') do
      render_inline(described_class.new(summary: summary(verdicts), active_step: 2, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('a.nav-link .data-fix-step-short.d-md-none', count: 4)
    expect(page).to have_css('a.nav-link .data-fix-step-label.d-none.d-md-inline', count: 4)
  end

  it 'renders plain tabs without a summary' do
    with_request_url('/data_fix/review_sessions') do
      render_inline(described_class.new(summary: nil, active_step: 1, file_path: '/x/242/a-lt4.json'))
    end
    expect(page).to have_css('ul.nav-tabs .nav-link', count: 5)
    expect(page).to have_no_css('[data-verdict]')
  end
end
