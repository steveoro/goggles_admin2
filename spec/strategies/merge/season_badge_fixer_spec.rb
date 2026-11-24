# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::SeasonBadgeFixer do
  include RakeParity::Fixtures

  let(:season) { GogglesDb::Season.find(RakeParity::Fixtures::SEASON) }
  # (badge 110785: swimmer 27655, team 54 of season 182)
  let(:other_team_badge) { GogglesDb::Badge.find(110_785) }

  before(:each) { hide_leftover_seasons! }

  it 'processes EVERY sure candidate without a team filter (the former task skipped them all)' do
    copy_a = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    copy_b = duplicate_badge(other_team_badge.id)
    fixer = described_class.new(season:).prepare
    expect(fixer.step).to eq(:sure)
    expect(fixer.counts).to eq(possible: nil, sure: 2, relay_only: 0, relay: 0)
    expect(fixer.planned.map(&:source_id)).to contain_exactly(copy_a.id, copy_b.id)
    expect(fixer.sql_log.first).to start_with("-- Season badge fix: season #{season.id}, step 1 'sure badge merges': 2 badge(s)")
    expect(fixer.sql_log.count { |line| line.include?('START TRANSACTION;') }).to eq(2) # (one transaction per badge)
  end

  it 'keeps the very SQL of each Merge::Badge (autofix), each badge in its own block' do
    copy = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    expected = Merge::Badge.new(source: copy, dest: GogglesDb::Badge.find(RakeParity::Fixtures::BADGE_A), autofix: true)
    expected.prepare
    fixer = described_class.new(season:).prepare
    expect(fixer.sql_log.drop(3)).to eq(expected.single_transaction_sql_log)
  end

  it 'filters on the source team with src_team_id, and forces over the destination team with dest_team_id' do
    duplicate_badge(RakeParity::Fixtures::BADGE_A)
    copy_b = duplicate_badge(other_team_badge.id)
    fixer = described_class.new(season:, src_team_id: other_team_badge.team_id).prepare
    expect(fixer.planned.map(&:source_id)).to eq([copy_b.id])
    expect(fixer.counts[:sure]).to eq(1)
    expect(fixer.planned.sole.mode).to eq(:autofix)
    forced = described_class.new(season:, src_team_id: other_team_badge.team_id, dest_team_id: other_team_badge.team_id).prepare
    expect(forced.planned.sole.mode).to eq(:force)
  end

  it 'leaves the possible merges out by default, and needs a team filter for them' do
    expect(described_class.new(season:).include_possible).to be(false)
    expect { described_class.new(season:, include_possible: true) }.to raise_error(ArgumentError, /src_team_id/)
    expect { described_class.new(season:, dest_team_id: 5) }.to raise_error(ArgumentError, /src_team_id/)
  end

  it 'plans the relay steps when no sure merge is left, and ends with no step when nothing is left (no endless step 3)' do
    relay_category!(RakeParity::Fixtures::BADGE_B)
    fixer = described_class.new(season:).prepare
    expect(fixer.step).to eq(:relay_only)
    expect(fixer.planned.sole).to have_attributes(source_id: RakeParity::Fixtures::BADGE_B, dest_id: nil)
    expect(described_class.new(season: GogglesDb::Season.find(192)).prepare.step).to be_nil
  end

  it 'defers a badge inserting a meeting program already inserted by another badge of the step' do
    copy_a = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    copy_b = duplicate_badge(other_team_badge.id)
    program = 'INSERT INTO meeting_programs (updated_at, meeting_event_id, category_type_id, gender_type_id, autofilled) VALUES (NOW(), 7, 8, 1, 1);'
    allow(Merge::Badge).to receive(:new) do |source:, **|
      instance_double(Merge::Badge, prepare: nil, single_transaction_sql_log: ['START TRANSACTION;', program, "-- #{source.id}", 'COMMIT;'])
    end
    fixer = described_class.new(season:).prepare
    expect(fixer.planned.size).to eq(1)
    expect(fixer.deferred.sole.message).to include('meeting program')
    expect([copy_a.id, copy_b.id]).to include(fixer.deferred.sole.source_id)
    expect(fixer.more_to_do?).to be(true)
  end

  it 'reports a failing badge without stopping the step' do
    copy_a = duplicate_badge(RakeParity::Fixtures::BADGE_A)
    duplicate_badge(other_team_badge.id)
    allow(Merge::Badge).to receive(:new).and_wrap_original do |original, source:, **options|
      raise 'Unrecoverable errors detected! Cannot continue.' if source.id == copy_a.id

      original.call(source:, **options)
    end
    fixer = described_class.new(season:).prepare
    expect(fixer.planned.size).to eq(1)
    expect(fixer.failed.sole).to have_attributes(source_id: copy_a.id, message: 'RuntimeError: Unrecoverable errors detected! Cannot continue.')
  end
end
