# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Registry do
  let(:locales) { %i[en it] }
  let(:texts) { %w[title description fix_label] }

  it 'lists the eight phase 11 operations with unique keys, known Outbox kinds and texts in en and it' do
    expect(described_class.keys).to eq(%w[meeting.set_cancelled badge.merge results.null_swimmers_fix results.dedupe ranks.recompute
                                          season_board.backfill swimmer.merge team.merge])
    described_class.all.each do |klass| # rubocop:disable Rails/FindEach -- an Array of classes
      expect(Outbox::Kinds.valid?(klass.outbox_kind)).to be(true), klass.key
      expect(Maintenance::Operation::CONFIRMATIONS).to include(klass.confirmation)
      expect(klass.health_group.nil? || Ops::HealthRun::GROUPS.include?(klass.health_group)).to be(true), klass.key
      klass.fixes.each { |check_key| expect(Health::Registry.find(check_key)).to be_present, "#{klass.key}: #{check_key}" }
      locales.each do |locale|
        texts.each do |text|
          expect(I18n.t("maintenance.operations.#{klass.i18n_key}.#{text}", locale:, default: nil)).to be_present, "#{locale}: #{klass.key}.#{text}"
        end
      end
    end
  end

  it 'gives a button to every phase-06 check whose "Button in" column names 11' do
    expected = %w[meetings.no_results.unflagged meetings.cancel_mismatch meetings.results_flag badges.duplicate.sure
                  badges.duplicate.possible badges.relay_category teams.possible_duplicates results.duplicates results.null_swimmers
                  results.dup_mir_per_badge swimmers.possible_duplicates]
    expected.each { |check_key| expect(described_class.for_check(check_key)).not_to be_empty, check_key }
  end

  it 'offers the operations of a finding (payload-driven), never on a resolved one' do
    cancel = FactoryBot.build(:ops_health_finding, check_key: 'meetings.no_results.unflagged', payload: { 'cancel' => { 'meeting_id' => 7 } })
    expect(described_class.for_finding(cancel).map(&:key)).to eq(['meeting.set_cancelled'])
    expect(described_class.for_finding(FactoryBot.build(:ops_health_finding, check_key: 'meetings.no_results.unflagged'))).to be_empty
    cancel.status = 'resolved'
    expect(described_class.for_finding(cancel)).to be_empty

    same_team = FactoryBot.build(:ops_health_finding, check_key: 'badges.duplicate.possible',
                                                      payload: { 'badges' => [{ 'id' => 1, 'team_id' => 5 }, { 'id' => 2, 'team_id' => 5 }] })
    expect(described_class.for_finding(same_team).map(&:key)).to eq(['badge.merge'])
    two_teams = FactoryBot.build(:ops_health_finding, check_key: 'badges.duplicate.possible',
                                                      payload: { 'badges' => [{ 'id' => 1, 'team_id' => 5 }, { 'id' => 2, 'team_id' => 6 }] })
    expect(described_class.for_finding(two_teams).map(&:key)).to eq(%w[badge.merge team.merge])
  end

  it 'fetches by key and raises for an unknown one' do
    expect(described_class.fetch('badge.merge')).to eq(Maintenance::Operations::BadgeMerge)
    expect(described_class.find('nope')).to be_nil
    expect { described_class.fetch('nope') }.to raise_error(KeyError)
  end
end
