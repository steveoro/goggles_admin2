# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::SeasonScope do
  let(:today) { Date.current }
  let(:closed) { closed_health_season }
  let(:empty_closed) { closed_health_season }
  let(:ongoing) { FactoryBot.create(:season, begin_date: today - 30.days, end_date: today + 200.days) }
  let(:upcoming) { FactoryBot.create(:season, begin_date: today + 30.days, end_date: today + 300.days) }
  let(:board) { FactoryBot.create(:season, begin_date: today - 400.days, end_date: today - 35.days) }
  let(:scope) { described_class.new(today:, board_season_id: board.id) }

  before(:each) do
    FactoryBot.create(:meeting, season: closed)
    [empty_closed, ongoing, upcoming, board].each(&:id)
  end

  it 'classifies the seasons: closed, current (ongoing or Season board season) and upcoming' do
    expect(scope.status_for(closed.id)).to eq(:closed)
    expect(scope.status_for(ongoing.id)).to eq(:current)
    expect(scope.status_for(upcoming.id)).to eq(:upcoming)
    expect(scope.status_for(board.id)).to eq(:current)
    expect(scope.current.map(&:season_id)).to include(ongoing.id, board.id)
  end

  it 'lists the closed seasons without meetings and badges as "no data", with no group to run' do
    expect(scope.entry(empty_closed.id)).to be_no_data
    expect(scope.groups_for(empty_closed.id)).to eq([])
    expect(scope.runnable.map(&:season_id)).not_to include(empty_closed.id)
    expect(scope.entry(closed.id)).to have_attributes(meetings_count: 1, badges_count: 0)
    expect(scope.groups_for(closed.id)).to eq(Ops::HealthRun::GROUPS)
  end

  it 'runs only the setup group for an upcoming season, every group for a current one' do
    expect(scope.groups_for(upcoming.id)).to eq(%w[setup])
    expect(scope.groups_for(ongoing.id)).to eq(Ops::HealthRun::GROUPS)
    expect(scope.groups_for(0)).to eq([])
  end
end
