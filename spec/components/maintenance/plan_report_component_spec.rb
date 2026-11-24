# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::PlanReportComponent, type: :component do
  it 'renders a ready dry run: facts, console without ANSI escapes, SQL and digest' do # rubocop:disable RSpec/MultipleExpectations
    run = FactoryBot.create(:ops_operation_run, :previewed, console: "\e[32mOK\e[0m checked", warnings: ['careful'],
                                                            summary: { 'confirmation' => 'one_click', 'empty' => false, 'statements' => 1,
                                                                       'meeting_id' => 7, 'counts' => { 'mirs' => 2 },
                                                                       'reviews_in_progress' => [{ 'base' => 'trofeo-x', 'stage' => 'needs_review' }] })
    render_inline(described_class.new(run:))
    expect(page).to have_css('#operation-run-outcome', text: I18n.t('maintenance.run.ready'))
    expect(page).to have_css('#operation-run-warnings li', text: 'careful')
    expect(page).to have_css('#operation-run-summary dd', text: '7')
    expect(page).to have_css('details[data-fact="counts"]')
    expect(page).to have_css('#operation-run-reviews', text: 'trofeo-x')
    expect(page).to have_css('#operation-run-console pre', text: 'OK checked', visible: :all)
    expect(page.find('#operation-run-console pre', visible: :all).text).not_to include("\e[")
    expect(page).to have_css('#operation-run-sql pre', text: 'UPDATE `meetings`')
    expect(page).to have_css('#operation-run-sql code', text: run.sql_digest)
  end

  it 'renders the refusal reason and the applied outcome with its Outbox link' do
    refused = FactoryBot.create(:ops_operation_run, mode: 'apply')
    refused.refuse!(:digest_changed)
    render_inline(described_class.new(run: refused))
    expect(page).to have_css('#operation-run-outcome', text: I18n.t('maintenance.refusals.digest_changed'))

    applied = FactoryBot.create(:ops_operation_run, :previewed, mode: 'apply', applied_locally: true,
                                                                summary: { 'sql_filename' => '0491-meeting_cancel-7.sql' })
    render_inline(described_class.new(run: applied))
    expect(page).to have_css('#operation-run-outcome', text: '0491-meeting_cancel-7.sql')
    expect(page).to have_link(I18n.t('maintenance.run.open_outbox'), href: '/outbox?focus=0491-meeting_cancel-7.sql')
  end

  it 'shows the pending state without the report sections' do
    render_inline(described_class.new(run: FactoryBot.create(:ops_operation_run)))
    expect(page).to have_css('#operation-run-outcome', text: I18n.t('maintenance.run.queued_text'))
    expect(page).to have_no_css('#operation-run-sql')
  end

  it 'renders an interrupted apply with the local DB warning and the new dry run link' do
    run = FactoryBot.create(:ops_operation_run, mode: 'apply', status: 'running', started_at: 1.hour.ago, params: { 'meeting_id' => 7 })
    render_inline(described_class.new(run:))
    expect(page).to have_css('#operation-run-state', text: I18n.t('maintenance.statuses.interrupted'))
    expect(page).to have_css('#operation-run-outcome.alert-danger', text: I18n.t('maintenance.run.interrupted_running').split(':').first)
    expect(page).to have_link(I18n.t('maintenance.run.new_dry_run'), href: '/operations/meeting.set_cancelled/new?meeting_id=7&origin=ui')
    expect(page).to have_no_css('.spinner-border')
  end
end
