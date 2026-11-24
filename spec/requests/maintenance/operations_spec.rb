# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Maintenance operations pages' do
  include AdminSignInHelpers

  let(:admin_user) { prepare_admin_user }
  let(:season) { closed_health_season }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  def page_body = response.parsed_body

  describe 'GET /operations' do
    it 'lists every operation with its form link, and the run history' do
      run = FactoryBot.create(:ops_operation_run, :previewed, label: 'Flag meeting 5 cancelled')
      get(operations_path)
      expect(response).to have_http_status(:success)
      keys = page_body.css('#operations-list tr[data-operation-key]').pluck('data-operation-key')
      expect(keys).to eq(Maintenance::Registry.keys)
      expect(page_body.at_css('#operations-list a[href="/operations/badge.merge/new"]')).to be_present
      expect(page_body.at_css("#operations-history a[href='#{maintenance_run_path(run)}']")).to be_present
      expect(page_body.at_css('[data-operation-status="succeeded"]')).to be_present
    end

    it 'says when the operations are disabled, without form links' do
      Ops::Setting.store!(Maintenance::ENABLED_SETTING, false)
      get(operations_path)
      expect(page_body.at_css('#operations-disabled')).to be_present
      expect(page_body.at_css('#operations-list a[href="/operations/badge.merge/new"]')).to be_nil
    end
  end

  describe 'GET /operations/:key/new' do
    it 'prefills the form from a finding the operation fixes' do
      finding = FactoryBot.create(:ops_health_finding, season_id: season.id, check_key: 'badges.duplicate.sure', group_key: 'badges',
                                                       payload: { 'rake' => { 'src' => 34, 'dest' => 12 },
                                                                  'title_args' => { 'name' => 'X', 'year' => 1970, 'count' => 2 } })
      get(new_operation_path(key: 'badge.merge', finding_id: finding.id))
      expect(response).to have_http_status(:success)
      form = page_body.at_css('#frm-operation')
      expect(form['action']).to eq(operation_runs_path(key: 'badge.merge'))
      expect(form.at_css('input[name="operation[source_id]"]')['value']).to eq('34')
      expect(form.at_css('input[name="operation[dest_id]"]')['value']).to eq('12')
      expect(form.at_css('input[name="operation[autofix]"]')['checked']).to be_present
      expect(form.at_css('input[name="operation[force]"]')['checked']).to be_nil
      expect(form.at_css('input[name="finding_id"]')['value']).to eq(finding.id.to_s)
      expect(page_body.at_css('#operation-form-finding a')['href']).to eq(health_finding_path(finding))
    end

    it 'prefills from the link params (commit report) and ignores a finding of another check' do
      finding = FactoryBot.create(:ops_health_finding, season_id: season.id)
      get(new_operation_path(key: 'results.dedupe', meeting_id: 77, origin: 'commit_report', finding_id: finding.id))
      form = page_body.at_css('#frm-operation')
      expect(form.at_css('input[name="operation[meeting_id]"]')['value']).to eq('77')
      expect(form.at_css('input[name="origin"]')['value']).to eq('commit_report')
      expect(form.at_css('input[name="finding_id"]')).to be_nil
    end

    it 'redirects an unknown operation to the list' do
      get(new_operation_path(key: 'nothing.here'))
      expect(response).to redirect_to(operations_path)
      expect(flash[:error]).to eq(I18n.t('maintenance.errors.unknown_operation'))
    end

    it 'keeps the old Flag cancelled URL working (redirect to the meeting.set_cancelled form)' do
      get('/health/cancellations/new?meeting_id=19412')
      follow_redirect!
      expect(page_body.at_css('input[name="operation[meeting_id]"]')['value']).to eq('19412')
    end
  end
end
