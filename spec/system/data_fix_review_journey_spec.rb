# frozen_string_literal: true

require 'rails_helper'

# Journey (phase 12, run in both themes: SYSTEM_THEME=dark): on a needs-review source, open Step 3 on "needs you only",
# fix two swimmers jumping with Next (saved in place, no page reload), edit an event in Step 4, see the Step 5 stale
# banner and rebuild it, open the commit summary and commit, see the report reach "committed" and follow its link to
# the Outbox.
#
# The source is a structure-only (meeting-only) file in a temporary crawler data root, with hand-written phase 1-5
# files stamped as built (so that a Step 4 edit makes Phase 5 stale; a result-free Phase 5 is never rebuilt by
# itself, which shows the banner). The API is stubbed and the commit job is performed by the example itself.
RSpec.describe 'Data-Fix review journey' do
  let(:admin_user) { prepare_admin_user }
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:new_dir) { data_root.join('results.new', '262').tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_file) { new_dir.join('wizard_journey-lt4.json').to_s }
  let(:season) { FactoryBot.create(:season) }
  let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
  let(:meeting_code) { "specwizard#{rand(100_000)}" }
  let(:candidates) { FactoryBot.create_list(:swimmer, 2) }
  let(:progress_broadcasts) { [] }
  let(:phase1_data) do
    {
      'season_id' => season.id, 'name' => 'Wizard Journey Meeting', 'code' => meeting_code,
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
  # Two swimmers with a candidate under the match bar (Step 3 "needs you") and a confidently new one
  let(:phase3_data) do
    swimmers = candidates.each_with_index.map do |candidate, index|
      { 'key' => "M|JOURNEY#{index}|ANDREA|1980", 'last_name' => "Journey#{index}", 'first_name' => 'Andrea', 'year_of_birth' => 1980,
        'gender_type_code' => 'M', 'complete_name' => "Journey#{index} Andrea", 'category_type_code' => 'M45', 'swimmer_id' => nil,
        'fuzzy_matches' => [{ 'id' => candidate.id, 'percentage' => 72.0, 'color_class' => 'warning',
                              'display_label' => "#{candidate.complete_name} (#{candidate.year_of_birth}, ID: #{candidate.id}, match: 72%)" }] }
    end
    { 'season_id' => season.id, 'swimmers' => swimmers, 'badges' => [] }
  end
  let(:phase4_data) do
    { 'sessions' => [{ 'session_order' => 1, 'description' => 'Session 1', 'events' => [
      { 'key' => '50SL', 'distance' => 50, 'stroke' => 'SL', 'event_order' => 1, 'session_order' => 1,
        'event_type_id' => GogglesDb::EventType.find_by(code: '50SL')&.id, 'heat_type_id' => GogglesDb::HeatType::FINALS_ID,
        'heat_type' => 'F', 'id' => nil }
    ] }] }
  end

  def write_phase(phase, data)
    PhaseFileManager.new(source_file.sub('.json', "-phase#{phase}.json")).write!(data:, meta: { 'generator' => 'spec' })
  end

  # Collects the ImportStatusChannel broadcasts from now on (server side) and logs, in the browser, every message the
  # page receives with the strip state once every listener handled it (the window outlives the Turbo visits).
  def record_progress_strip
    allow(ActionCable.server).to receive(:broadcast).and_wrap_original do |original, channel, payload, **options|
      progress_broadcasts << payload if channel == Import::Progress::Cable::CHANNEL
      original.call(channel, payload, **options)
    end
    page.execute_script(<<~JS)
      window.__stripLog = []
      document.addEventListener('import-status', (event) => {
        const entry = { op: event.detail.op, done: event.detail.state === 'done' }
        setTimeout(() => {
          const panel = document.getElementById('progress-strip-panel')
          window.__stripLog.push({ ...entry, hidden: panel ? panel.hidden : null })
        }, 0)
      })
    JS
  end

  # The browser log of #record_progress_strip for +op_id+, once it holds its +count+ messages.
  def recorded_progress_strip(op_id:, count:)
    log = nil
    page.document.synchronize(10) do
      log = page.evaluate_script('window.__stripLog').select { |entry| entry['op'] == op_id }
      raise Capybara::ExpectationNotMet, "#{log.size}/#{count} messages received" if log.size < count
    end
    log
  end

  before(:each) do
    allow(Outbox).to receive(:data_root).and_return(data_root)
    allow(Outbox::RemoteStatusJob).to receive(:perform_later)
    allow(APIProxy).to receive(:ping).and_return(APIProxy::Result.new(DummyResponse.new(body: { msg: 'OK', version: '7.0.1' }.to_json)))
    FactoryBot.create(:ops_db_fingerprint, :unknown, api_base_url: APIProxy.configured_base_url.to_s.delete_suffix('/'))
    File.write(source_file, JSON.pretty_generate('_meta' => { 'meeting_only' => true }, 'layoutType' => 4,
                                                 'meetingName' => 'Wizard Journey Meeting', 'seasonId' => season.id, 'events' => []))
    write_phase(1, phase1_data)
    write_phase(2, { 'season_id' => season.id, 'teams' => [] })
    write_phase(3, phase3_data)
    write_phase(4, phase4_data)
    write_phase(5, { 'name' => 'phase5', 'source_file' => File.basename(source_file), 'programs' => [] })
    pipeline = DataFix::Pipeline.for(source_file, progress: Import::Progress::Null.new, actor: :auto)
    (1..5).each { |phase| pipeline.send(:stamp_built!, phase) }
    sign_in_through_form(admin_user)
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'fixes two swimmers in place, edits an event, rebuilds the stale Step 5, commits and reaches the Outbox' do # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
    # 1. Step 3 opens on "needs you only"
    visit(review_swimmers_path(file_path: source_file, phase3_v2: 1))
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 3')
    expect(page).to have_checked_field('turbo-filter-state-swimmers-per-page-review', visible: :all)
    expect(page).to have_css('[id^="swimmer-card-"][data-issue]', count: 2)
    page.execute_script('window.__journeyNoReload = true')

    # 2-3. Next issue (button, then the j key), save each card in place
    2.times do |round|
      round.zero? ? click_button('btn-issue-next') : find('body').send_keys('j')
      card_id = find('.issue-nav-current[data-issue]')[:id]
      within("##{card_id}") do
        expect(page).to have_css('.collapse.show', wait: 5)
        sleep(0.4) # (collapse transition)
        fill_in("swimmer_#{card_id.delete_prefix('swimmer-card-')}_first_name", with: "Fixed#{round}")
        click_button(I18n.t('data_fix.wizard.buttons.save_swimmer'))
      end
      expect(page).to have_css("##{card_id} .data-fix-confirmed-badge", wait: 10)
      expect(page).to have_no_css("##{card_id}[data-issue]")
    end
    expect(page).to have_no_css('[id^="swimmer-card-"][data-issue]')
    expect(page.evaluate_script('window.__journeyNoReload')).to be(true)
    expect(page).to have_css('#data-fix-step-edited')
    swimmers = PhaseFileManager.new(source_file.sub('.json', '-phase3.json')).data['swimmers']
    expect(swimmers.pluck('first_name')).to contain_exactly('Fixed0', 'Fixed1')
    expect(swimmers.pluck('confirmed')).to all(be(true))

    # 4. Edit an event in Step 4 (its begin time and event type)
    click_link('Step 4 • Events')
    expect(page).to have_css('#event-card-0')
    find_by_id('event-header-0').click
    expect(page).to have_css('#event-panel-0.show')
    sleep(0.4)
    # (a time input: typed keys depend on the browser locale, the value is set directly)
    page.execute_script("document.getElementById('event_0_begin_time').value = '09:15'")
    # (a new event type: an input of Phase 5, which becomes stale; set like the LegacyAutoComplete does, so that no
    # blur-time layout change of the widget swallows the click on Save)
    page.execute_script(<<~JS)
      const field = document.getElementById('event_event_type_id')
      field.value = '#{GogglesDb::EventType.find_by(code: '100SL').id}'
      field.dispatchEvent(new Event('change', { bubbles: true }))
    JS
    sleep(0.3)
    click_button(I18n.t('data_fix.wizard.buttons.save_event'))
    expect(page).to have_css('#flash-messages-container .toast', wait: 10) # (the save redirects back with a notice)
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 4')
    expect(PhaseFileManager.new(source_file.sub('.json', '-phase4.json')).data.dig('sessions', 0, 'events', 0, 'begin_time')).to eq('09:15')

    # 5. Step 5 is stale: rebuild it from the banner
    click_link('Step 5 • Results')
    expect(page).to have_css('#data-fix-step-stale', text: I18n.t('data_fix.stepper.inputs.events'))
    record_progress_strip
    click_button('btn-data-fix-rebuild-phase')
    expect(page).to have_no_css('#data-fix-step-stale')
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 5')
    # The rebuild broadcasts its progress for real (one op: ticks, then 'done'); the strip showed it, then hid on the
    # 'done', and nothing is modal.
    op = progress_broadcasts.first[:op]
    expect(progress_broadcasts.first).to include(op:, seq: 1, scope: File.basename(source_file, '.json'))
    expect(progress_broadcasts.last).to eq({ op:, state: 'done' })
    expect(progress_broadcasts.pluck(:op)).to all(eq(op))
    strip_log = recorded_progress_strip(op_id: op, count: progress_broadcasts.size)
    done_at = strip_log.index { |entry| entry['done'] }
    expect(strip_log.first(done_at)).to all(include('hidden' => false)) # (each tick received before the 'done' showed it)
    expect(strip_log.drop(done_at)).to all(include('hidden' => true)) # (the 'done' hid it; a late tick never reopens it)
    expect(page).to have_css('#progress-strip-panel', visible: :hidden)
    expect_no_modal_backdrop

    # 6-8. Commit summary, commit, report
    click_link('btn-commit-summary-link')
    expect(page).to have_css('#data-fix-commit-summary')
    check('commit-drift-ack')
    accept_confirm { click_button('btn-commit-summary') }
    expect(page).to have_css('#commit-report-state', text: I18n.t('data_fix.commit_report.statuses.queued'))
    report = Ops::CommitReport.last
    DataFixCommitJob.perform_now(commit_report_id: report.id)
    expect(page).to have_css('#commit-report-state', text: I18n.t('data_fix.commit_report.statuses.committed'), wait: 10)

    # 9. The report links the script in the Outbox
    script = Ops::SqlScript.find_by!(kind: 'commit', folder: '262')
    click_link(script.filename)
    expect(page).to have_css("#outbox-script-#{script.id}[data-outbox-focus='true']")
    expect_no_js_errors
  end
end
