# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Registry do
  let(:locales) { %i[en it] }
  let(:texts) { %w[title description fix_label] }

  it 'lists the eight phase 11 and the nine phase 13 operations with unique keys, known Outbox kinds and texts in en and it' do
    expect(described_class.keys).to eq(%w[meeting.set_cancelled badge.merge results.null_swimmers_fix results.dedupe ranks.recompute
                                          season_board.backfill swimmer.merge team.merge
                                          meeting.merge meeting.team_fix badge.team_fix badge.swimmer_fix meeting.purge
                                          coded_names.normalize categories.clone standard_timings.import season.badge_fix])
    expect(described_class.keys).to eq(described_class.keys.uniq)
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

  it 'lists the eight read-only inspectors of phase 13 apart (dry run only, no Outbox kind), with texts in en and it' do
    expect(described_class.inspector_keys).to eq(%w[team.check swimmer.check badge.check season.badges team.map_badges swimmer.map_mirs
                                                    team.dup_badges meeting.dup_mir_badges])
    expect(described_class.inspector_keys & described_class.keys).to be_empty
    described_class.inspectors.each do |klass|
      expect(klass).to be_inspector
      expect(klass.outbox_kind).to be_nil
      expect(klass.fixes).to be_empty
      expect(described_class.find(klass.key)).to eq(klass)
      locales.each do |locale|
        texts.each do |text|
          expect(I18n.t("maintenance.operations.#{klass.i18n_key}.#{text}", locale:, default: nil)).to be_present, "#{locale}: #{klass.key}.#{text}"
        end
      end
    end
  end

  it 'gives the season-wide badge fix (phase 13) to the sure duplicate and relay category checks' do
    %w[badges.duplicate.sure badges.relay_category].each do |check_key|
      expect(described_class.for_check(check_key)).to include(Maintenance::Operations::SeasonBadgeFix), check_key
    end
    finding = FactoryBot.build(:ops_health_finding, check_key: 'badges.duplicate.sure', season_id: 182, payload: { 'rake' => { 'src' => 2, 'dest' => 1 } })
    expect(described_class.for_finding(finding).map(&:key)).to eq(%w[badge.merge season.badge_fix])
    expect(Maintenance::Operations::SeasonBadgeFix.from_finding(finding).to_params).to eq('season_id' => 182)
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
