# frozen_string_literal: true

require 'rails_helper'

# Phase 12 (Data-Fix wizard UX): Step 2/3 cards saved in place (Turbo streams), the "needs you only" defaults, the
# next/previous issue markers, POST data_fix/rebuild_phase and "Verify all".
RSpec.describe 'Data-Fix wizard UX' do
  include AdminSignInHelpers

  let(:temp_dir) { Dir.mktmpdir }
  let(:season) { FactoryBot.create(:season) }
  let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' } }
  let(:teams) do
    [{ 'key' => 'Team A', 'name' => 'Team A', 'editable_name' => 'Team A', 'team_id' => nil, 'fuzzy_matches' => [] },
     { 'key' => 'Team B', 'name' => 'Team B', 'editable_name' => 'Team B', 'team_id' => nil, 'fuzzy_matches' => [] }]
  end
  let(:swimmers) do
    [{ 'key' => 'M|DOE|JOHN|1985|Team A', 'last_name' => 'Doe', 'first_name' => 'John', 'year_of_birth' => 1985,
       'gender_type_code' => 'M', 'complete_name' => 'DOE JOHN', 'swimmer_id' => nil, 'fuzzy_matches' => [] }]
  end
  let(:badges) { [{ 'swimmer_key' => 'M|DOE|JOHN|1985|Team A', 'team_key' => 'Team A', 'team_id' => nil, 'season_id' => season.id }] }

  def source_in(dir, name = 'wizard_source')
    path = File.join(dir, "#{name}.json")
    File.write(path, JSON.generate({ 'layoutType' => 4, 'name' => 'Wizard Meeting', 'teams' => { 'Team A' => 'Team A' } }))
    path
  end

  def write_phase(source, phase, data)
    PhaseFileManager.new(source.sub('.json', "-phase#{phase}.json")).write!(data:, meta: { 'generator' => 'test' })
  end

  def phase_data(source, phase)
    PhaseFileManager.new(source.sub('.json', "-phase#{phase}.json")).data
  end

  # (Turbo stream bodies: parsed as plain HTML, so that the <template> contents can be queried)
  def stream_doc
    Nokogiri::HTML4(response.body) # rubocop:disable Rails/ResponseParsedBody -- (parsed_body is a String for this media type)
  end

  def frame_id(kind, key)
    "#{kind}-card-k-#{Digest::SHA1.hexdigest(key)[0, 10]}"
  end

  before(:each) { sign_in_admin(prepare_admin_user) }

  after(:each) { FileUtils.rm_rf(temp_dir) }

  describe 'PATCH update_phase2_team (saved in place)' do
    let(:params) { { team_key: 'Team A', card_index: 0, filter_state: 'review', team: { editable_name: 'Team A Edited', name: 'Team A' } } }

    def prepare(source)
      write_phase(source, 2, { 'season_id' => season.id, 'teams' => teams })
      write_phase(source, 3, { 'season_id' => season.id, 'swimmers' => swimmers, 'badges' => badges })
    end

    it 'answers Turbo streams replacing the card, the stepper and the toasts, writing the same phase file as the HTML path' do # rubocop:disable RSpec/MultipleExpectations
      html_source = source_in(FileUtils.mkdir_p(File.join(temp_dir, 'html')).first)
      stream_source = source_in(FileUtils.mkdir_p(File.join(temp_dir, 'stream')).first)
      [html_source, stream_source].each { |source| prepare(source) }

      patch update_phase2_team_path, params: params.merge(file_path: html_source)
      expect(response).to have_http_status(:redirect)

      patch update_phase2_team_path, params: params.merge(file_path: stream_source), headers: stream_headers
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      streams = stream_doc.css('turbo-stream')
      expect(streams.map { |node| [node['action'], node['target']] }).to include(
        ['replace', frame_id('team', 'Team A')], %w[replace data-fix-stepper], %w[update flash-messages-container]
      )
      card = streams.find { |node| node['target'] == frame_id('team', 'Team A') }
      expect(card.at_css("turbo-frame##{frame_id('team', 'Team A')}[target='_top'] #team-card-0")).to be_present
      expect(card.text).to include('Team A Edited')
      expect(card.at_css('#team-card-0')['data-issue']).to be_nil # (saved = confirmed: no longer "needs you")
      expect(streams.find { |node| node['target'] == 'data-fix-stepper' }.css('ul.nav-tabs .nav-link').size).to eq(5)

      expect(phase_data(stream_source, 2)).to eq(phase_data(html_source, 2))
      expect(phase_data(stream_source, 3)).to eq(phase_data(html_source, 3))
      expect(PhaseFileManager.new(stream_source.sub('.json', '-phase2.json')).meta['operator_edit']['actions']).to eq(['update_phase2_team'])
    end

    it 'replaces the team ranking card too when the source has team scores' do
      source = source_in(temp_dir)
      write_phase(source, 2, { 'season_id' => season.id, 'teams' => teams,
                               'team_scores' => [{ 'team_key' => 'Team A', 'rank' => 1, 'ind_score' => 10, 'overall_score' => 12 }] })
      patch update_phase2_team_path, params: params.merge(file_path: source), headers: stream_headers
      expect(stream_doc.css('turbo-stream[action="replace"][target="phase2-team-scores-card"]')).to be_present
    end

    it 'warns, naming them, when the save gave other teams new Phase 3 hints (their cards are not replaced)' do
      source = source_in(temp_dir)
      prepare(source)
      allow(DataFix::Phase3Harmonizer).to receive(:harmonize_phase2_phase3_team_links) do |source_path:, **|
        pfm = PhaseFileManager.new(source_path.sub('.json', '-phase2.json'))
        data = pfm.data
        data['teams'][1]['fuzzy_matches'] = [{ 'id' => 1, 'from_phase3_conflict_hint' => true, 'phase3_conflict_reason' => 'badges' }]
        pfm.write!(data:, meta: pfm.meta)
        DataFix::Phase3Harmonizer.empty_phase3_consistency_stats.merge(phase2_conflict_hints_added: 1)
      end
      patch update_phase2_team_path, params: params.merge(file_path: source), headers: stream_headers
      toasts = stream_doc.at_css('turbo-stream[action="update"][target="flash-messages-container"]').text
      expect(toasts).to include(I18n.t('data_fix.flash.team_hints_changed', count: 1, teams: 'Team B'))
    end

    it 'does not warn when no other team got a new hint' do
      source = source_in(temp_dir)
      prepare(source)
      patch update_phase2_team_path, params: params.merge(file_path: source), headers: stream_headers
      expect(response.body).not_to include(I18n.t('data_fix.flash.team_hints_changed', count: 1, teams: 'Team B').split('(').first)
    end

    it 'refuses the save with a toast stream while the source is being built' do
      source = source_in(temp_dir)
      prepare(source)
      Ops::PipelineSource.for_path!(source).acquire_lease!('job:abc', ttl: 10.minutes)
      patch update_phase2_team_path, params: params.merge(file_path: source), headers: stream_headers
      expect(response).to have_http_status(:conflict)
      expect(stream_doc.css('turbo-stream[action="update"][target="flash-messages-container"]').text)
        .to include(I18n.t('pipeline_automation.review.edit_refused'))
      expect(phase_data(source, 2)['teams'][0]['editable_name']).to eq('Team A')
    end
  end

  describe 'PATCH update_phase3_swimmer (saved in place)' do
    let(:params) { { swimmer_key: swimmers[0]['key'], card_index: 3, swimmer: { complete_name: 'DOE JOHNNY', first_name: 'Johnny', last_name: 'Doe' } } }

    it 'answers Turbo streams replacing the card (same position) and the stepper, writing the same phase file as the HTML path' do
      html_source = source_in(FileUtils.mkdir_p(File.join(temp_dir, 'html')).first)
      stream_source = source_in(FileUtils.mkdir_p(File.join(temp_dir, 'stream')).first)
      [html_source, stream_source].each do |source|
        write_phase(source, 3, { 'season_id' => season.id, 'swimmers' => swimmers, 'badges' => badges })
      end

      patch update_phase3_swimmer_path, params: params.merge(file_path: html_source)
      expect(response).to have_http_status(:redirect)

      patch update_phase3_swimmer_path, params: params.merge(file_path: stream_source), headers: stream_headers
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      streams = stream_doc.css('turbo-stream')
      card = streams.find { |node| node['target'] == frame_id('swimmer', swimmers[0]['key']) }
      expect(card).to be_present
      expect(card.at_css('#swimmer-card-3')).to be_present
      expect(card.text).to include('DOE JOHNNY')
      expect(streams.pluck('target')).to include('data-fix-stepper', 'flash-messages-container')
      expect(phase_data(stream_source, 3)).to eq(phase_data(html_source, 3))
    end
  end

  describe '"needs you only" defaults and issue markers' do
    let(:source) { source_in(temp_dir) }

    before(:each) do
      matched = FactoryBot.create(:team)
      confirmed = { 'key' => 'Team C', 'name' => 'Team C', 'editable_name' => 'Team C', 'team_id' => matched.id, 'confirmed' => true,
                    'fuzzy_matches' => [{ 'id' => matched.id, 'percentage' => 100.0, 'display_label' => 'Team C' }] }
      write_phase(source, 2, { 'season_id' => season.id, 'teams' => teams + [confirmed] })
    end

    it 'opens Step 2 on the "needs you" filter when no cookie is set, with one marker per card needing the operator' do
      get review_teams_path(file_path: source, phase2_v2: 1)
      expect(response).to be_successful
      page = response.parsed_body
      expect(page.at_css('input[name="filter_state"][value="review"][checked]')).to be_present
      expect(page.css('[id^="team-card-"][data-issue]').size).to eq(2)
      expect(page.text).not_to include('Team C')
      nav = page.at_css("#data-fix-issue-nav[data-controller='issue-nav']")
      expect(nav['data-issue-nav-total-value']).to eq('2')
      expect(nav['data-action']).to include('keydown@window->issue-nav#keydown')
    end

    it 'lets an explicit filter_state=none win and remembers it' do
      get review_teams_path(file_path: source, phase2_v2: 1, filter_state: 'none')
      expect(response.parsed_body.text).to include('Team C')
      get review_teams_path(file_path: source, phase2_v2: 1)
      expect(response.parsed_body.at_css('input[name="filter_state"][value="none"][checked]')).to be_present
      expect(response.parsed_body.text).to include('Team C')
    end

    it 'links the next issue on a later page through its card anchor' do
      get review_teams_path(file_path: source, phase2_v2: 1, filter_state: 'none', teams_per_page: 1, teams_page: 3)
      nav = response.parsed_body.at_css('#data-fix-issue-nav')
      expect(nav['data-issue-nav-prev-url-value']).to include('teams_page=2').and include('#team-card-1')
      expect(nav['data-issue-nav-next-url-value']).to eq('')
    end
  end

  describe 'Step 1 "copy pool & city from session" with "needs you only"' do
    let(:source) { source_in(temp_dir) }
    let(:swimming_pool) { FactoryBot.create(:swimming_pool) }
    let(:valid_session) do
      { 'id' => nil, 'description' => 'Session 1', 'session_order' => 1, 'scheduled_date' => '2026-10-24',
        'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
        'swimming_pool' => { 'id' => swimming_pool.id, 'name' => swimming_pool.name, 'nick_name' => swimming_pool.nick_name,
                             'address' => swimming_pool.address, 'pool_type_id' => swimming_pool.pool_type_id,
                             'lanes_number' => swimming_pool.lanes_number, 'city_id' => swimming_pool.city_id } }
    end

    before(:each) do
      invalid_session = valid_session.merge('description' => 'Session 2', 'session_order' => 2, 'scheduled_date' => nil)
      write_phase(source, 1, { 'season_id' => season.id, 'name' => 'Wizard Meeting', 'meeting_session' => [valid_session, invalid_session] })
    end

    it 'offers only the sessions on the page, and says how many are hidden' do
      get review_sessions_path(file_path: source, phase_v2: 1)
      page = response.parsed_body
      expect(page.at_css('#session-card-0')).to be_nil
      expect(page.at_css('#session-card-1[data-issue]')).to be_present
      expect(page.at_css('#copy_from_session_1')).to be_nil
      hint = page.at_css('#copy-from-session-hidden-1')
      expect(hint.text).to include(I18n.t('data_fix.wizard.sessions.copy_show_all'))
      expect(hint.at_css('a')['href']).to include('issues_only=0')

      get review_sessions_path(file_path: source, phase_v2: 1, issues_only: '0')
      expect(response.parsed_body.css('#copy_from_session_1 option').pluck('value')).to eq(['', '0'])
      expect(response.parsed_body.at_css('#copy-from-session-hidden-1')).to be_nil
      expect(response.parsed_body.at_css("#copy-from-session-feedback-1[data-session-card-target='copyFeedback']")).to be_present
    end
  end

  describe 'Step 4 "needs you only" toggle' do
    let(:source) { source_in(temp_dir) }

    before(:each) do
      write_phase(source, 1, { 'season_id' => season.id, 'name' => 'Wizard Meeting',
                               'meeting_session' => [{ 'session_order' => 1, 'description' => 'S1' }] })
      write_phase(source, 4, { 'sessions' => [{ 'session_order' => 1, 'events' => [
                    { 'key' => '100SL', 'distance' => 100, 'stroke' => 'SL', 'event_order' => 1 },
                    { 'key' => 'ZZZ99', 'event_order' => 2 }
                  ] }] })
    end

    it 'shows only the events needing the operator by default, and everything with issues_only=0' do
      get review_events_path(file_path: source, phase4_v2: 1)
      page = response.parsed_body
      expect(page.css('div[id^="event-card-"]').pluck('data-issue')).to eq(['event_type_unresolved'])
      expect(page.at_css('#btn-data-fix-issues-only[aria-pressed="true"]')).to be_present

      get review_events_path(file_path: source, phase4_v2: 1, issues_only: '0')
      expect(response.parsed_body.css('div[id^="event-card-"]').size).to eq(2)
    end
  end

  describe 'POST data_fix/rebuild_phase' do
    let(:source) { source_in(temp_dir) }
    let(:phase1_file) { source.sub('.json', '-phase1.json') }

    before(:each) { write_phase(source, 1, { 'season_id' => season.id, 'name' => 'Hand edited', 'meeting_session' => [] }) }

    def mark_edited!
      DataFix::Pipeline.for(source, progress: Import::Progress::Null.new).mark_edited!(1, action: 'update_phase1_meeting')
    end

    it 'refuses an edited phase without force, leaving the file untouched' do
      mark_edited!
      before = File.binread(phase1_file)
      post data_fix_rebuild_phase_path, params: { file_path: source, phase: 1 }
      expect(response).to redirect_to(review_sessions_path(file_path: source, phase_v2: 1))
      expect(flash[:warning]).to eq(I18n.t('data_fix.rebuild.refused_edited', number: 1))
      expect(File.binread(phase1_file)).to eq(before)
    end

    it 'rebuilds an edited phase with force (the edits are discarded)' do
      mark_edited!
      post data_fix_rebuild_phase_path, params: { file_path: source, phase: 1, force: '1' }
      expect(response).to redirect_to(review_sessions_path(file_path: source, phase_v2: 1))
      expect(flash[:notice]).to be_present
      expect(PhaseFileManager.new(phase1_file).meta['operator_edit']).to be_nil
      expect(PhaseFileManager.new(phase1_file).meta.dig('built', 'by')).to be_present
    end

    it 'rejects an unknown phase' do
      post data_fix_rebuild_phase_path, params: { file_path: source, phase: 9 }
      expect(flash[:warning]).to eq(I18n.t('data_fix.rebuild.invalid_phase'))
    end
  end

  describe 'POST data_fix/verify_all_results ("Verify all")' do
    let(:source) { source_in(temp_dir) }

    it 'reopens Step 5 with its filters and the fixed / partial / none counts' do
      outcome = { 'checked' => 5, 'verified' => 2, 'partial' => %w[a b], 'merge_targets_skipped' => 0 }
      allow(DataFix::ResultVerifier).to receive(:new).and_return(instance_double(DataFix::ResultVerifier, verify_all!: outcome))
      post data_fix_verify_all_results_path, params: { file_path: source, filter_issues: '0', page: 2 }
      expect(response).to redirect_to(review_results_path(file_path: source, filter_issues: '0', page: '2', phase5_v2: 1))
      expect(flash[:notice]).to eq(I18n.t('data_fix.verify_all.done', checked: 5, fixed: 2, partial: 2, none: 1))
    end

    it 'reports a failed run' do
      allow(DataFix::ResultVerifier).to receive(:new)
        .and_return(instance_double(DataFix::ResultVerifier, verify_all!: { 'checked' => 0, 'verified' => 0, 'partial' => [], 'error' => 'boom' }))
      post data_fix_verify_all_results_path, params: { file_path: source }
      expect(flash[:error]).to eq(I18n.t('data_fix.verify_all.failed', error: 'boom'))
    end
  end
end
