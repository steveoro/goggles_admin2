# frozen_string_literal: true

require 'rails_helper'

# Phase 13 review: a standard-timings script never becomes pushable before the remote season exists, whatever path
# applied it locally, and its release puts it after the scripts registered meanwhile (Outbox order = push order).
RSpec.describe 'Outbox: standard timings held until the remote season exists' do # rubocop:disable RSpec/DescribeClass
  include RakeParity::Fixtures

  let(:data_root) { Pathname.new(Dir.mktmpdir('st_hold')) }
  let(:runner) { maintenance_sql_runner }

  before(:each) { allow(APIProxy).to receive(:call).and_raise('no API call expected') }

  after(:each) { FileUtils.rm_rf(data_root) }

  def held_standard_timings(rel_path, **attributes)
    create_sql_script(data_root, rel_path, kind: 'standard_timings', season_id: 262, state: 'held', **attributes)
  end

  it 'goes back to held "remote_season_missing" when a script-only standard timings script is applied from the Outbox' do
    source = standard_timings_xlsx(data_root.join('src').to_s)
    out = StringIO.new
    status = Maintenance::RakeRunner.call('import:standard_timings', env: { 'season' => '262', 'source' => source }, out:,
                                                                     input: StringIO.new, data_root:, gate: maintenance_gate(:ok))
    expect(status).to be_nil
    script = Ops::SqlScript.find_by(kind: 'standard_timings')
    script.data_root = data_root
    expect(script).to have_attributes(state: 'held', held_reason: 'not_applied_locally', folder: '262')
    expect(script.origin).to include('held_after_local_apply' => 'remote_season_missing')

    Outbox::ScriptActions.apply_locally!(script, runner:)
    expect(script.reload).to have_attributes(state: 'held', held_reason: 'remote_season_missing', applied_locally: true)
    expect(Outbox::ScriptActions.can_apply_locally?(script)).to be(false)
    expect(Maintenance::SeasonStart::Checklist.new(season_id: 262).held_scripts).to eq([script])
    expect(Outbox::PushPlan.new(scope: 'all_pending').scripts).not_to include(script)
  end

  it 'keeps the former behaviour for a script without the hold in its origin (pending after the local apply)' do
    script = held_standard_timings('results.new/262/0007-262-standard_timings.sql', held_reason: 'not_applied_locally', applied_locally: false)
    Outbox::ScriptActions.apply_locally!(script, runner:)
    expect(script.reload).to have_attributes(state: 'pending', held_reason: nil, applied_locally: true)
  end

  it 'gives a released "remote_season_missing" script the next seq, so that it is pushed after the ones registered meanwhile' do
    held = held_standard_timings('results.new/262/0009-262-standard_timings.sql', held_reason: 'remote_season_missing', seq: 9)
    later = create_sql_script(data_root, 'results.new/misc/0010-merge_badges-1-2.sql', seq: 10)
    expect(Outbox::PushPlan.new(scope: 'all_pending').scripts).to eq([later])

    Outbox::ScriptActions.release!(held)
    held.reload
    expect(held).to have_attributes(state: 'pending', seq: 11, filename: '0011-262-standard_timings.sql')
    expect(data_root.join('results.new/262/0011-262-standard_timings.sql')).to exist
    expect(Outbox::PushPlan.new(scope: 'all_pending').scripts).to eq([later, held])
  end

  it 'keeps the seq of an operator hold on release (phase 07 behaviour)' do
    held = create_sql_script(data_root, 'results.new/misc/0009-merge_teams-1-2.sql', seq: 9, state: 'held', held_reason: 'operator')
    create_sql_script(data_root, 'results.new/misc/0010-merge_badges-1-2.sql', seq: 10)
    Outbox::ScriptActions.release!(held)
    expect(held.reload).to have_attributes(state: 'pending', seq: 9)
  end
end
