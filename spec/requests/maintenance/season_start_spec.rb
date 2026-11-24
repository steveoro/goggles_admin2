# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Season-start checklist' do
  include AdminSignInHelpers
  include OutboxHelpers

  let(:admin_user) { prepare_admin_user }
  let(:season) { FactoryBot.create(:season) }
  let(:timings_dir) { Pathname.new(Dir.mktmpdir('st_timings')) }
  let(:data_root) { Pathname.new(Dir.mktmpdir('st_outbox')) }

  before(:each) do
    sign_in_admin(admin_user)
    allow(APIProxy).to receive(:call).and_raise('no API call expected')
    allow(Outbox).to receive(:data_root).and_return(data_root)
    Maintenance::SeasonStart::Checklist.standard_timings_dir = timings_dir
  end

  after(:each) do
    Maintenance::SeasonStart::Checklist.standard_timings_dir = Import::StandardTimings::BASE_DIR
    FileUtils.rm_rf(timings_dir)
    FileUtils.rm_rf(data_root)
  end

  RemoteResponse = Struct.new(:code, :body) # rubocop:disable Lint/ConstantDefinitionInBlock,RSpec/LeakyConstantDeclaration

  def page_body = response.parsed_body
  def post_step(step_key, perform, season_id: season.id, **params) = post(season_start_step_path(season_id, step_key), params: { perform:, **params })
  def items = Ops::SeasonChecklistItem.where(season_id: season.id)

  # A season whose steps 1-5 are done (Season row, a category, migrations confirmed, source file, standard timings).
  def ready_to_step6!
    category = FactoryBot.create(:category_type, season:)
    Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'migrations', status: 'done', done_at: Time.current)
    FileUtils.mkdir_p(timings_dir.join(season.id.to_s))
    File.write(timings_dir.join(season.id.to_s, "mst_tb_ind_#{season.begin_date.year}.xlsx"), 'x')
    FactoryBot.create(:standard_timing, season:, category_type: category)
  end

  describe 'GET pages' do
    it 'shows the season picker with the latest FIN Masters seasons and redirects a picked season' do
      get(season_start_index_path)
      expect(response).to have_http_status(:success)
      expect(page_body.at_css('#frm-season-start')).to be_present
      get(season_start_index_path(season_id: season.id))
      expect(response).to redirect_to(season_start_path(season.id))
    end

    it 'shows the eight steps, the not-ready ones disabled, without any API call' do
      get(season_start_path(season.id))
      expect(response).to have_http_status(:success)
      steps = page_body.css('#season-start-steps li[data-step-key]')
      expect(steps.pluck('data-step-key')).to eq(Maintenance::SeasonStart::Checklist::STEP_KEYS)
      expect(steps.pluck('data-step-status')).to eq(%w[done pending blocked blocked blocked blocked blocked blocked])
      expect(page_body.at_css('#season-start-migrations button[value="confirm"]')['disabled']).to be_present
      expect(page_body.at_css('#season-start-remote_season button')['disabled']).to be_present
    end

    it 'renders a season without a local row (step 1 pending)' do
      get(season_start_path(9_999_990))
      expect(response).to have_http_status(:success)
      expect(page_body.css('#season-start-steps li').first['data-step-status']).to eq('pending')
    end
  end

  describe 'POST a step out of order' do
    # (every step but the first, with the Season row missing: nothing is ready after step 1)
    { 'category_types' => 'repair', 'migrations' => 'confirm', 'standard_timings_file' => 'upload',
      'standard_timings_import' => 'operation', 'remote_season' => 'check_remote', 'static_calendars' => 'skip',
      'season_board_backfill' => 'operation' }.each do |step_key, perform|
      it "refuses '#{step_key}' (#{perform}) before the previous steps are done" do
        post_step(step_key, perform, season_id: 9_999_990)
        expect(response).to redirect_to(season_start_path(9_999_990, anchor: "season-start-#{step_key}"))
        expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.not_ready'))
        expect(Ops::SeasonChecklistItem.where(season_id: 9_999_990)).to be_empty
        expect(APIProxy).not_to have_received(:call)
      end
    end

    it "refuses 'migrations' while the season has no CategoryType (step 2 not done)" do
      post_step('migrations', 'confirm')
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.not_ready'))
      expect(items).to be_empty
    end

    it 'refuses the first step: it has no action (instructions only)' do
      post_step('seasons_exist', 'confirm', season_id: 9_999_990)
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.no_action'))
    end

    it 'refuses an action that is not the step one, and an unknown step' do
      FactoryBot.create(:category_type, season:)
      post_step('migrations', 'check_remote')
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.no_action'))
      post_step('nope', 'confirm')
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.unknown_step'))
    end

    it 'refuses a data step already done (read from the data)' do
      ready_to_step6!
      post_step('standard_timings_import', 'operation')
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.already_done'))
    end
  end

  describe 'POST a ready step' do
    it 'confirms, reopens and skips the operator tick boxes' do
      FactoryBot.create(:category_type, season:)
      post_step('migrations', 'confirm', note: 'done on all four')
      expect(items.sole).to have_attributes(step_key: 'migrations', status: 'done', note: 'done on all four', done_by: admin_user.id)
      post_step('migrations', 'reopen')
      expect(items.sole.reload).to have_attributes(status: 'pending', done_at: nil)
      post_step('migrations', 'skip')
      expect(items.sole.reload.status).to eq('skipped')
    end

    it 'uploads the source file into the season folder (xlsx or csv only)' do
      FactoryBot.create(:category_type, season:)
      Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'migrations', status: 'done', done_at: Time.current)
      text = Rack::Test::UploadedFile.new(StringIO.new('x'), original_filename: 'notes.txt')
      post_step('standard_timings_file', 'upload', file: text)
      expect(flash[:error]).to eq(I18n.t('maintenance.season_start.flash.upload_invalid'))
      file = Rack::Test::UploadedFile.new(StringIO.new('x'), original_filename: '../mst_tb_ind_2026.xlsx')
      post_step('standard_timings_file', 'upload', file:)
      expect(flash[:info]).to include('mst_tb_ind_2026.xlsx')
      expect(timings_dir.join(season.id.to_s, 'mst_tb_ind_2026.xlsx')).to exist
      expect(Dir.children(timings_dir)).to eq([season.id.to_s])
    end

    it 'opens the prefilled dry run form of the standard timings import' do
      FactoryBot.create(:category_type, season:)
      Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'migrations', status: 'done', done_at: Time.current)
      FileUtils.mkdir_p(timings_dir.join(season.id.to_s))
      File.write(timings_dir.join(season.id.to_s, "mst_tb_ind_#{season.begin_date.year}.xlsx"), 'x')
      post_step('standard_timings_import', 'operation')
      expect(response).to redirect_to(new_operation_path(key: 'standard_timings.import', season_id: season.id))
    end

    it 'checks the remote season on demand and releases the held standard timings once it exists' do
      ready_to_step6!
      script = create_sql_script(data_root, "results.new/#{season.id}/0009-#{season.id}-standard_timings.sql",
                                 kind: 'standard_timings', season_id: season.id, state: 'held', held_reason: 'remote_season_missing', seq: 9)
      create_sql_script(data_root, 'results.new/misc/0010-merge_badges-1-2.sql', seq: 10)
      allow(APIProxy).to receive(:call).and_return(APIProxy::Result.new(RemoteResponse.new(404, '{"error":"not found"}')))
      post_step('remote_season', 'check_remote')
      expect(flash[:warning]).to eq(I18n.t('maintenance.season_start.flash.remote_missing', id: season.id))
      expect(script.reload).to be_held

      allow(APIProxy).to receive(:call).and_return(APIProxy::Result.new(RemoteResponse.new(200, { id: season.id }.to_json)))
      post_step('remote_season', 'check_remote')
      expect(APIProxy).to have_received(:call).with(hash_including(method: :get, url: "season/#{season.id}")).twice
      expect(flash[:info]).to eq(I18n.t('maintenance.season_start.flash.remote_found', count: 1))
      expect(script.reload).to have_attributes(state: 'pending', held_reason: nil)
      expect(script).to have_attributes(seq: 11, filename: "0011-#{season.id}-standard_timings.sql") # (after the later scripts)
      expect(items.find_by(step_key: 'remote_season')).to be_done
    end
  end
end
