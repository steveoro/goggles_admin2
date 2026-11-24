# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::SeasonStart::Checklist do
  include OutboxHelpers

  let(:season) { FactoryBot.create(:season) }
  let(:timings_dir) { Pathname.new(Dir.mktmpdir('st_timings')) }
  let(:data_root) { Pathname.new(Dir.mktmpdir('st_outbox')) }

  before(:each) { described_class.standard_timings_dir = timings_dir }

  after(:each) do
    described_class.standard_timings_dir = Import::StandardTimings::BASE_DIR
    FileUtils.rm_rf(timings_dir)
    FileUtils.rm_rf(data_root)
  end

  def checklist(id = season.id) = described_class.new(season_id: id)

  def statuses(list) = list.steps.to_h { |step| [step.key, step.status] }

  it 'lists the eight steps in order; without the Season row only the first one is ready' do
    list = checklist(9_999_990)
    expect(list.steps.map(&:key)).to eq(described_class::STEP_KEYS)
    expect(list.steps.map(&:number)).to eq((1..8).to_a)
    expect(statuses(list)).to eq('seasons_exist' => 'pending', 'category_types' => 'blocked', 'migrations' => 'blocked',
                                 'standard_timings_file' => 'blocked', 'standard_timings_import' => 'blocked',
                                 'remote_season' => 'blocked', 'static_calendars' => 'blocked', 'season_board_backfill' => 'blocked')
    expect(list.step('seasons_exist').facts.sole).to include('9999990')
  end

  it 're-derives the data steps on every view (Season row, CategoryTypes, source file, standard timings)' do
    expect(statuses(checklist)).to include('seasons_exist' => 'done', 'category_types' => 'pending', 'migrations' => 'blocked')
    FactoryBot.create(:category_type, season:)
    expect(statuses(checklist)).to include('category_types' => 'done', 'migrations' => 'pending', 'standard_timings_file' => 'blocked')

    Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'migrations', status: 'skipped')
    expect(statuses(checklist)).to include('migrations' => 'skipped', 'standard_timings_file' => 'pending')

    FileUtils.mkdir_p(timings_dir.join(season.id.to_s))
    File.write(timings_dir.join(season.id.to_s, "mst_tb_ind_#{season.begin_date.year}-x.xlsx"), 'x')
    expect(statuses(checklist)).to include('standard_timings_file' => 'done', 'standard_timings_import' => 'pending')

    FactoryBot.create(:standard_timing, season:, category_type: season.category_types.first)
    expect(statuses(checklist)).to include('standard_timings_import' => 'done', 'remote_season' => 'pending', 'static_calendars' => 'blocked')
  end

  it 'keeps the remote season step open while a standard-timings script of the season is held' do
    script = create_sql_script(data_root, "results.new/#{season.id}/0007-#{season.id}-standard_timings.sql",
                               kind: 'standard_timings', season_id: season.id, state: 'held', held_reason: 'remote_season_missing')
    Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'remote_season', status: 'done', done_at: Time.current)
    list = checklist
    expect(list.held_scripts).to eq([script])
    expect(list.step('remote_season').done?).to be(false)
    expect(list.step('standard_timings_import').facts.last).to include('1')
    script.update!(state: 'pending', held_reason: nil)
    expect(checklist.step('remote_season').done?).to be(true)
  end

  it 'offers the categories clone only as a repair: no local category and the remote season known to exist' do
    previous = FactoryBot.create(:season, season_type: season.season_type, id: season.id - 1)
    expect(checklist.step('category_types').action).to be_nil
    Ops::SeasonChecklistItem.create!(season_id: season.id, step_key: 'remote_season', status: 'done', done_at: Time.current)
    step = checklist.step('category_types')
    expect(step.action).to eq(:repair)
    expect(step.operation).to eq('key' => 'categories.clone', 'params' => { 'src_season_id' => previous.id, 'dest_season_id' => season.id })
  end

  it 'marks the backfill done only when the board season is the new one and a backfill was applied for it' do
    allow(SeasonDefaults).to receive(:default_season_id).and_return(season.id)
    expect(checklist.step('season_board_backfill').done?).to be(false)
    FactoryBot.create(:ops_operation_run, operation_key: 'season_board.backfill', params: { 'season_id' => season.id }, season_id: season.id,
                                          mode: 'apply', status: 'succeeded')
    step = checklist.step('season_board_backfill')
    expect(step.done?).to be(true)
    expect(step.facts.first).to eq(I18n.t('maintenance.season_start.steps.season_board_backfill.default_ok', id: season.id))
    allow(SeasonDefaults).to receive(:default_season_id).and_return(season.id - 10)
    expect(checklist.step('season_board_backfill').done?).to be(false)
  end
end
