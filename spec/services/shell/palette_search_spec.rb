# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe Shell::PaletteSearch do
  let(:data_dir) { Pathname.new(Dir.mktmpdir) }
  let(:session_index) { DataFix::SessionIndex.new(data_dir:) }

  after(:each) { FileUtils.remove_entry(data_dir) }

  def search(query) = described_class.new(query, session_index:).results

  it 'searches nothing under two characters' do
    expect(search('z')).to eq([])
    expect(search(' ')).to eq([])
  end

  it 'finds a meeting by a fragment of its name, leading to the meetings grid filtered on it' do
    meeting = FactoryBot.create(:meeting, description: 'Trofeo Zqpalette Masters')
    result = search('zqpalette').find { |row| row.kind == :meeting }
    expect(result).to have_attributes(label: 'Trofeo Zqpalette Masters', icon: 'fa-flag-checkered')
    expect(result.detail).to eq(I18n.t('shell.palette.meeting_detail', date: meeting.header_date, season: meeting.season_id))
    expect(result.path).to eq(Rails.application.routes.url_helpers.api_meetings_path(
                                meetings_grid: { name: meeting.description, season_id: meeting.season_id }
                              ))
  end

  it 'finds teams and swimmers by name, and a meeting by its id' do
    team = FactoryBot.create(:team, name: 'Zqpalette Swim Team')
    swimmer = FactoryBot.create(:swimmer, first_name: 'Ada', last_name: 'Zqpalette', complete_name: 'ZQPALETTE ADA')
    results = search('zqpalette')
    expect(results.find { |row| row.kind == :team }.path).to eq(Rails.application.routes.url_helpers.api_teams_path(teams_grid: { name: team.name }))
    expect(results.find { |row| row.kind == :swimmer }).to have_attributes(label: 'ZQPALETTE ADA', detail: swimmer.year_of_birth.to_s)

    meeting = GogglesDb::Meeting.last
    expect(search(meeting.id.to_s).map { |row| [row.kind, row.label] }).to include([:meeting, meeting.description])
  end

  it 'finds a Data-Fix session by the words of its source file name, leading to its Resume step' do
    season_dir = data_dir.join('results.new', '9997')
    FileUtils.mkdir_p(season_dir)
    File.write(season_dir.join('2026-11-22-Trofeo_Zqpalette-lt4.json'), '{}')
    File.write(season_dir.join('2026-11-22-Trofeo_Zqpalette-lt4-phase2.json'), '{}')

    result = search('trofeo zqpalette').find { |row| row.kind == :data_fix_session }
    expect(result).to have_attributes(label: '2026-11-22-Trofeo_Zqpalette-lt4.json', icon: 'fa-wand-magic')
    expect(result.detail).to eq(I18n.t('shell.palette.session_detail', season: 9997, phase: 2))
    expect(result.path).to start_with('/data_fix/review_teams?file_path=')
    expect(search('zqpalette missing').none? { |row| row.kind == :data_fix_session }).to be(true)
  end

  it 'returns at most 20 results, shared among the kinds, grouped by kind' do
    FactoryBot.create_list(:meeting, 3, description: 'Zqcap Meeting')
    22.times { |n| FactoryBot.create(:swimmer, complete_name: "ZQCAP SWIMMER #{n}") }
    results = search('zqcap')
    expect(results.size).to eq(described_class::MAX_RESULTS)
    expect(results.count { |row| row.kind == :meeting }).to eq(3)
    expect(results.count { |row| row.kind == :swimmer }).to eq(17)
    expect(results.map(&:kind).chunk_while { |a, b| a == b }.map(&:first)).to eq(%i[meeting swimmer])
  end

  it 'serializes a result with its kind label' do
    FactoryBot.create(:team, name: 'Zqpalette Swim Team')
    hash = search('zqpalette').first.to_h
    expect(hash).to include(kind: :team, label: 'Zqpalette Swim Team', kind_label: I18n.t('shell.palette.kinds.team'))
    expect(hash.keys).to contain_exactly(:kind, :kind_label, :label, :detail, :path, :icon)
  end
end
