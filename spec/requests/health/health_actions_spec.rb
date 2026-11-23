# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Data health actions' do
  include AdminSignInHelpers
  include ActiveJob::TestHelper

  let(:admin_user) { prepare_admin_user }
  let(:season) { closed_health_season }

  before(:each) do
    FactoryBot.create(:meeting, season:)
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
  end

  # (not memoized: several requests per example)
  def page_body = response.parsed_body

  def finding(**attributes)
    FactoryBot.create(:ops_health_finding, season_id: season.id, **attributes)
  end

  describe 'PATCH /health/findings/bulk' do
    let(:return_to) { health_section_path(season.id, 'meetings.no_results.unflagged') }

    it 'acknowledges the selection, storing the status change and one event' do
      rows = [finding, finding]
      patch(health_findings_bulk_path, params: { ids: rows.map(&:id), operation: 'acknowledge', return_to: })
      expect(response).to redirect_to(return_to)
      expect(rows.map { |row| row.reload.status }).to eq(%w[acknowledged acknowledged])
      expect(rows.first).to have_attributes(status_changed_by: admin_user.id, status_changed_at: be_present)
      event = Ops::Event.of_kind('health.findings_triaged').sole
      expect(event.data).to include('operation' => 'acknowledge', 'count' => 2)
      expect(flash[:notice]).to eq(I18n.t('health.bulk.done.acknowledge', count: 2, skipped: 0))
    end

    it 'requires a note to ignore, then stores it' do
      row = finding
      patch(health_findings_bulk_path, params: { ids: [row.id], operation: 'ignore', note: ' ', return_to: })
      expect(flash[:alert]).to eq(I18n.t('health.bulk.errors.note_required'))
      expect(row.reload.status).to eq('open')

      patch(health_findings_bulk_path, params: { ids: [row.id], operation: 'ignore', note: 'no results published', return_to: })
      expect(row.reload).to have_attributes(status: 'ignored', note: 'no results published')
    end

    it 'reopens acknowledged and ignored findings, skipping the others, and refuses an external return_to' do
      acknowledged = finding(status: 'acknowledged')
      resolved = finding(status: 'resolved')
      patch(health_findings_bulk_path, params: { ids: [acknowledged.id, resolved.id], operation: 'reopen', return_to: 'https://evil.example' })
      expect(response).to redirect_to(health_path)
      expect([acknowledged.reload.status, resolved.reload.status]).to eq(%w[open resolved])
      expect(flash[:notice]).to eq(I18n.t('health.bulk.done.reopen', count: 1, skipped: 1))
    end
  end

  describe 'POST /health/runs' do
    it 'enqueues one group of a season (maintenance queue), skipping it while pending' do
      expect { post(health_runs_path, params: { season_id: season.id, group: 'meetings', return_to: health_season_path(season.id) }) }
        .to have_enqueued_job(Health::SeasonRunJob).on_queue('maintenance').exactly(1).times
      expect(response).to redirect_to(health_season_path(season.id))
      expect(Ops::HealthRun.for_season(season.id).pending.pluck(:group_key, :trigger)).to eq([%w[meetings manual]])
      expect(Ops::Event.of_kind('health.runs_requested').count).to eq(1)

      expect { post(health_runs_path, params: { season_id: season.id, group: 'meetings' }) }.not_to have_enqueued_job(Health::SeasonRunJob)
      expect(flash[:info]).to eq(I18n.t('health.runs.nothing_queued'))
    end

    it 'enqueues every group of a season' do
      expect { post(health_runs_path, params: { season_id: season.id }) }
        .to have_enqueued_job(Health::SeasonRunJob).exactly(Ops::HealthRun::GROUPS.size).times
    end

    it 'enqueues every runnable season with "Run all", at the sweep priority' do
      scope = instance_double(Health::SeasonScope, runnable: [health_entry(season, status: :closed)],
                                                   groups_for: Ops::HealthRun::GROUPS)
      allow(Health::SeasonScope).to receive(:new).and_return(scope)
      expect { post(health_runs_path, params: { all: '1' }) }
        .to have_enqueued_job(Health::SeasonRunJob).at_priority(Health::SeasonRunJob::PRIORITY_SWEEP).exactly(5).times
    end
  end

  describe 'Flag cancelled' do
    let(:data_root) { Pathname.new(Dir.mktmpdir) }
    let(:meeting) { FactoryBot.create(:meeting, season:, cancelled: false) }
    let(:calendar) { FactoryBot.create(:calendar, season:, meeting:, cancelled: false) }
    let(:unflagged) do
      finding(subject_id: meeting.id, payload: { 'cancel' => { 'meeting_id' => meeting.id, 'calendar_id' => calendar.id },
                                                 'title_args' => { 'id' => meeting.id, 'date' => '-', 'description' => 'x' } })
    end

    before(:each) { stub_const('SeasonBoard::Backfill::DEFAULT_DATA_ROOT', data_root) }

    after(:each) { FileUtils.rm_rf(data_root) }

    it 'previews the SQL without writing anything' do
      get(new_health_cancellation_path(finding_id: unflagged.id))
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#health-cancellation-sql').text).to include('UPDATE `meetings`', 'UPDATE `calendars`')
      expect(page_body.at_css('#health-cancellation-form input[name="digest"]')['value']).to be_present
      expect(meeting.reload.cancelled).to be(false)
      expect(Dir.glob(data_root.join('**/*.sql').to_s)).to be_empty
    end

    it 'applies it on click with the preview digest: local flag, numbered script, event, meetings re-run, Outbox link' do
      digest = Health::MeetingCanceller.new(season:, meeting_id: meeting.id, calendar_id: calendar.id).preview.digest
      expect { post(health_cancellations_path, params: { finding_id: unflagged.id, digest: }) }
        .to have_enqueued_job(Health::SeasonRunJob).exactly(1).times
      script = "0001-meeting_cancel-#{meeting.id}.sql"
      expect(response).to redirect_to(health_finding_path(unflagged, cancelled: script))
      expect([meeting.reload.cancelled, calendar.reload.cancelled]).to eq([true, true])
      expect(File).to exist(data_root.join('results.new', season.id.to_s, script))
      expect(Ops::Event.of_kind('health.meeting_cancelled').sole.data).to include('sql_filename' => script)
      expect(Ops::HealthRun.for_season(season.id).pending.pluck(:group_key)).to eq(['meetings'])

      follow_redirect!
      notice = page_body.at_css('#health-cancelled-notice')
      expect(notice.text).to include(script)
      expect(notice.at_css('a')['href']).to eq(outbox_path(focus: script))
    end

    it 'refuses a stale digest and a meeting with results' do
      post(health_cancellations_path, params: { finding_id: unflagged.id, digest: 'old' })
      expect(response).to redirect_to(new_health_cancellation_path(finding_id: unflagged.id))
      expect(flash[:error]).to include(I18n.t('health.cancellations.errors.digest_changed'))

      health_add_mir(meeting)
      get(new_health_cancellation_path(finding_id: unflagged.id))
      expect(page_body.at_css('#health-cancellation-error').text).to eq(I18n.t('health.cancellations.errors.has_results'))
      expect(page_body.at_css('#health-cancellation-form')).to be_nil
      expect(meeting.reload.cancelled).to be(false)
    end
  end
end
