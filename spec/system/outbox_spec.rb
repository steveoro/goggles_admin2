# frozen_string_literal: true

require 'rails_helper'

# Journey: commit a fixture meeting (structure-only source) -> report link -> Outbox entry -> push with a stubbed
# API -> "On the server" ("sent, not verified"). Everything lives in a temporary crawler data root and the API is
# stubbed (APIProxy.ping / APIProxy.call): nothing is posted anywhere. The push job (queued by the click) is
# performed by the example itself, as the Solid Queue worker would.
RSpec.describe 'SQL Outbox' do
  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:new_dir) { data_root.join('results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_file) { new_dir.join('outbox_journey-lt4.json').to_s }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "specjourney#{rand(100_000)}" }
  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Outbox Journey Meeting', 'code' => meeting_code,
      'header_year' => '2026/2027', 'header_date' => '2026-10-24', 'edition' => 1,
      'edition_type_id' => GogglesDb::EditionType::ORDINAL_ID, 'timing_type_id' => GogglesDb::TimingType::AUTOMATIC_ID,
      'dateYear1' => 2026, 'dateMonth1' => 10, 'dateDay1' => 24,
      'meeting_session' => [
        {
          'id' => nil, 'description' => 'Session 1, 2026-10-24', 'session_order' => 1, 'scheduled_date' => '2026-10-24',
          'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
          'swimming_pool' => {
            'id' => swimming_pool.id, 'name' => swimming_pool.name, 'nick_name' => swimming_pool.nick_name,
            'address' => swimming_pool.address, 'pool_type_id' => swimming_pool.pool_type_id,
            'lanes_number' => swimming_pool.lanes_number, 'city_id' => swimming_pool.city_id
          }
        }
      ]
    }
  end

  before(:each) do
    allow(Outbox).to receive(:data_root).and_return(data_root)
    allow(Outbox::RemoteStatusJob).to receive(:perform_later)
    allow(APIProxy).to receive(:ping).and_return(APIProxy::Result.new(DummyResponse.new(body: { msg: 'OK', version: '7.0.1' }.to_json)))
    File.write(source_file, JSON.pretty_generate('_meta' => { 'meeting_only' => true }, 'layoutType' => 4,
                                                 'meetingName' => 'Outbox Journey Meeting', 'seasonId' => season.id, 'events' => []))
    PhaseFileManager.new(source_file.sub('.json', '-phase1.json')).write!(data: phase1_data, meta: { 'generator' => 'spec' })
    PhaseFileManager.new(source_file.sub('.json', '-phase5.json')).write!(
      data: { 'name' => 'phase5', 'source_file' => File.basename(source_file), 'programs' => [] }, meta: { 'generator' => 'spec' }
    )
    sign_in_through_form(admin_user)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'commits, opens the script in the Outbox, pushes it and shows it on the server' do # rubocop:disable RSpec/MultipleExpectations
    visit(review_results_path(file_path: source_file, phase5_v2: 1))
    accept_confirm { click_button(I18n.t('data_import.data_fix.btn_commit_structure')) }
    expect(page).to have_text('Phase 6 commit completed successfully.')

    script = Ops::SqlScript.find_by!(kind: 'commit', folder: '262')
    click_link(script.filename)
    expect(page).to have_css("#outbox-script-#{script.id}[data-outbox-focus='true']")
    expect(page).to have_css("#outbox-script-#{script.id} [data-outbox-state='pending']")

    click_link(script.filename)
    click_link('btn-outbox-push-this')
    expect(page).to have_css('#outbox-push-list li', count: 1)
    fill_in('confirm_label', with: 'unknown')
    allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: { msg: 'OK', new: { id: 4321 } }.to_json))
    click_button('btn-outbox-push-confirm')
    expect(page).to have_current_path(%r{/outbox\?run=\d+})
    run = Ops::PushRun.last
    expect(page).to have_text(I18n.t('outbox.runs.started', id: run.id, count: 1))

    Outbox::PushJob.perform_now(run.id)
    visit(outbox_path(folder: 'all', focus: script.filename))
    within('#outbox-on-server-table') do
      expect(page).to have_css("#outbox-script-#{script.id} [data-outbox-state='sent']", text: I18n.t('outbox.states.sent'))
      expect(page).to have_text('4321')
    end
    expect(data_root.join('results.sent/262', script.filename)).to exist
    expect_no_js_errors
  end
end
