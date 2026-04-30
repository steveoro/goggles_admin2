# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::TeamInBadge do
  # Find a badge that has MIRs and belongs to a team with a TeamAffiliation,
  # then pick a different team (also with a TA in the same season) as the destination.
  let(:badge_with_mirs) do
    GogglesDb::MeetingIndividualResult
      .joins(:badge)
      .limit(200).sample
      &.badge
  end

  let(:season) { badge_with_mirs.season }

  # Find a different team that has a TeamAffiliation for the same season
  # and that the badge's swimmer does NOT already have a badge for.
  let(:new_team) do
    GogglesDb::TeamAffiliation
      .where(season_id: season.id)
      .where.not(team_id: badge_with_mirs.team_id)
      .where.not(
        team_id: GogglesDb::Badge
                   .where(swimmer_id: badge_with_mirs.swimmer_id, season_id: season.id)
                   .select(:team_id)
      )
      .limit(50).sample
      &.team
  end

  before(:each) do
    skip('No suitable badge with MIRs found in test DB') unless badge_with_mirs
    skip('No suitable destination team found in test DB') unless new_team
  end

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_team:) }

      it 'creates an instance' do
        expect(fixer).to be_a(described_class)
      end

      it 'stores the badges' do
        expect(fixer.badges).to eq([badge_with_mirs])
      end

      it 'stores the new_team' do
        expect(fixer.new_team).to eq(new_team)
      end

      it 'derives the seasons from the badge batch' do
        expect(fixer.seasons.map(&:id)).to contain_exactly(season.id)
      end

      it 'resolves the destination TeamAffiliation' do
        expect(fixer.dest_tas_by_season[season.id]).to be_a(GogglesDb::TeamAffiliation)
        expect(fixer.dest_tas_by_season[season.id].team_id).to eq(new_team.id)
        expect(fixer.dest_tas_by_season[season.id].season_id).to eq(season.id)
      end

      it 'initializes empty sql_log' do
        expect(fixer.sql_log).to eq([])
      end

      it 'initializes the badge_batch' do
        expect(fixer.badge_batch).to be_an(ActiveRecord::Relation)
        expect(fixer.badge_batch).to include(badge_with_mirs)
      end

      it 'defaults nuke_team to false (surgical mode)' do
        expect(fixer.nuke_team).to be(false)
      end

      it 'accepts nuke_team=true' do
        nuke_fixer = described_class.new(badges: [badge_with_mirs], new_team:, nuke_team: true)
        expect(nuke_fixer.nuke_team).to be(true)
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when badges is not an Array' do
        expect { described_class.new(badges: 'not an array', new_team:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when badges is empty' do
        expect { described_class.new(badges: [], new_team:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when badges contains non-Badge objects' do
        expect { described_class.new(badges: ['not a badge'], new_team:) }
          .to raise_error(ArgumentError, /must be a non-empty Array/)
      end

      it 'raises ArgumentError when new_team is not a Team' do
        expect { described_class.new(badges: [badge_with_mirs], new_team: 'not a team') }
          .to raise_error(ArgumentError, /must be a Team/)
      end

      it 'raises ArgumentError when badge already belongs to the destination team' do
        same_team = badge_with_mirs.team
        expect { described_class.new(badges: [badge_with_mirs], new_team: same_team) }
          .to raise_error(ArgumentError, /already belong to the destination team/)
      end

      it 'does not raise when dest team has no TeamAffiliation for the season (fallback mode)' do
        unaffiliated_team = GogglesDb::Team
                            .where.not(id: GogglesDb::TeamAffiliation.where(season_id: season.id).select(:team_id))
                            .first
        skip('No unaffiliated team found in test DB') unless unaffiliated_team

        expect { described_class.new(badges: [badge_with_mirs], new_team: unaffiliated_team) }
          .not_to raise_error
      end
    end
  end

  describe 'accessor methods' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_team:) }

    describe '#affected_mirs' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_mirs).to be_an(ActiveRecord::Relation)
      end

      it 'returns MIRs linked to badge_batch badges' do
        fixer.affected_mirs.each do |mir|
          expect(fixer.badge_batch.pluck(:id)).to include(mir.badge_id)
        end
      end
    end

    describe '#affected_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_mrr_ids' do
      it 'returns an Array' do
        expect(fixer.affected_mrr_ids).to be_an(Array)
      end
    end

    describe '#affected_mrrs' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_mrrs).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_relay_laps' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_relay_laps).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_entries' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_entries).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_reservations).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_event_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_event_reservations).to be_an(ActiveRecord::Relation)
      end
    end

    describe '#affected_meeting_relay_reservations' do
      it 'returns an ActiveRecord Relation' do
        expect(fixer.affected_meeting_relay_reservations).to be_an(ActiveRecord::Relation)
      end
    end
  end

  describe '#display_report' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_team:) }

    it 'outputs to stdout without raising' do
      expect { fixer.display_report }.to output.to_stdout
    end

    it 'includes season information in output' do
      expect { fixer.display_report }.to output(/Seasons.*#{season.id}/).to_stdout
    end

    it 'includes new team information in output' do
      expect { fixer.display_report }.to output(/New.*correct.*team.*#{new_team.id}/).to_stdout
    end

    it 'includes badge count in output' do
      expect { fixer.display_report }.to output(/Badges to update/).to_stdout
    end
  end

  describe '#prepare' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_team:) }

    before(:each) { fixer.prepare }

    it 'populates sql_log' do
      expect(fixer.sql_log).not_to be_empty
    end

    it 'starts with transaction control' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('SET AUTOCOMMIT = 0')
      expect(sql).to include('START TRANSACTION')
    end

    it 'ends with COMMIT' do
      expect(fixer.sql_log.last).to eq('COMMIT;')
    end

    it 'includes badge update SQL (Step 1)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 1')
      expect(sql).to include('UPDATE badges')
      expect(sql).to include("team_id = #{new_team.id}")
    end

    it 'includes MIR update SQL (Step 2)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 2')
      expect(sql).to include('UPDATE meeting_individual_results')
    end

    it 'includes lap update SQL (Step 3)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 3')
      expect(sql).to include('UPDATE laps')
    end

    it 'includes entry deletion SQL (Step 6)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 6')
      expect(sql).to include('DELETE FROM meeting_entries')
    end

    it 'includes reservation deletion SQL (Steps 7-9)' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 7')
      expect(sql).to include('DELETE FROM meeting_event_reservations')
      expect(sql).to include('Step 8')
      expect(sql).to include('DELETE FROM meeting_relay_reservations')
      expect(sql).to include('Step 9')
      expect(sql).to include('DELETE FROM meeting_reservations')
    end

    it 'uses correct team and badge IDs in SQL' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include("team_id = #{new_team.id}")
      expect(sql).to include(badge_with_mirs.id.to_s)
    end

    it 'uses correct TeamAffiliation ID in SQL' do
      sql = fixer.sql_log.join("\n")
      expect(sql).to include("team_affiliation_id = #{fixer.dest_tas_by_season[season.id].id}")
    end

    it 'prevents multiple runs' do
      initial_log_size = fixer.sql_log.size
      fixer.prepare
      expect(fixer.sql_log.size).to eq(initial_log_size)
    end
  end

  describe 'duplicate badge detection' do
    # Create a scenario where the swimmer already has a badge on the destination team
    let(:swimmer_with_two_badges) do
      GogglesDb::Badge
        .select(:swimmer_id, :season_id)
        .group(:swimmer_id, :season_id)
        .having('COUNT(DISTINCT team_id) > 1')
        .limit(1)
        .first
    end

    it 'populates errors when duplicate badges exist' do
      skip('No swimmer with multiple team badges found in test DB') unless swimmer_with_two_badges

      badges_for_swimmer = GogglesDb::Badge.where(
        swimmer_id: swimmer_with_two_badges.swimmer_id,
        season_id: swimmer_with_two_badges.season_id
      ).to_a
      src_badge = badges_for_swimmer.first
      dest_team = GogglesDb::Team.find(badges_for_swimmer.second.team_id)

      # Ensure dest_team has a TA for the season
      ta = GogglesDb::TeamAffiliation.find_by(team_id: dest_team.id, season_id: src_badge.season_id)
      skip('Destination team has no TA for season') unless ta

      fixer = described_class.new(badges: [src_badge], new_team: dest_team)
      expect(fixer.errors).not_to be_empty
    end

    it 'raises on prepare when duplicate badges exist and suggests merge:badge' do
      skip('No swimmer with multiple team badges found in test DB') unless swimmer_with_two_badges

      badges_for_swimmer = GogglesDb::Badge.where(
        swimmer_id: swimmer_with_two_badges.swimmer_id,
        season_id: swimmer_with_two_badges.season_id
      ).to_a
      src_badge = badges_for_swimmer.first
      dest_team = GogglesDb::Team.find(badges_for_swimmer.second.team_id)

      ta = GogglesDb::TeamAffiliation.find_by(team_id: dest_team.id, season_id: src_badge.season_id)
      skip('Destination team has no TA for season') unless ta

      fixer = described_class.new(badges: [src_badge], new_team: dest_team)
      expect { fixer.prepare }.to raise_error(RuntimeError, /Please run merge:badge first/)
    end
  end

  describe 'team affiliation fallback SQL generation' do
    subject(:fixer) { described_class.new(badges: [badge_with_mirs], new_team:) }

    let(:unaffiliated_team) do
      GogglesDb::Team
        .where.not(id: GogglesDb::TeamAffiliation.where(season_id: season.id).select(:team_id))
        .first
    end

    it 'defaults to surgical mode and creates missing destination TeamAffiliation' do
      skip('No unaffiliated team found in test DB') unless unaffiliated_team

      surgical_fixer = described_class.new(badges: [badge_with_mirs], new_team: unaffiliated_team)
      surgical_fixer.prepare

      sql = surgical_fixer.sql_log.join("\n")
      expect(sql).to include('Mode: nuke_team=0 (create missing TeamAffiliations)')
      expect(sql).to include("creating missing TeamAffiliation for destination team #{unaffiliated_team.id}")
      expect(sql).to include('INSERT INTO team_affiliations (team_id, season_id, name, created_at, updated_at)')
      expect(sql).not_to include('reusing TeamAffiliation')
    end

    it 'reuses source TeamAffiliation when nuke_team=1' do
      skip('No unaffiliated team found in test DB') unless unaffiliated_team

      reused_ta_id = badge_with_mirs.team_affiliation_id
      skip('Badge has no TeamAffiliation to reuse') if reused_ta_id.blank?

      nuke_fixer = described_class.new(badges: [badge_with_mirs], new_team: unaffiliated_team, nuke_team: true)
      nuke_fixer.prepare

      sql = nuke_fixer.sql_log.join("\n")
      expect(sql).to include('Mode: nuke_team=1 (reuse TeamAffiliations)')
      expect(sql).to include("reusing TeamAffiliation #{reused_ta_id}")
      expect(sql).to include("UPDATE team_affiliations SET team_id = #{unaffiliated_team.id}, updated_at = NOW() WHERE id = #{reused_ta_id};")
    end

    it 'emits recycle SQL when fallback mode is reuse' do
      reused_ta_id = badge_with_mirs.team_affiliation_id
      skip('Badge has no TeamAffiliation to reuse') if reused_ta_id.blank?

      fixer.instance_variable_set(:@sql_log, [])
      fixer.instance_variable_set(:@dest_ta_resolution_by_season, {
                                    season.id => { mode: :recycle, ta_id: reused_ta_id, source_team_id: badge_with_mirs.team_id }
                                  })
      fixer.instance_variable_set(:@dest_ta_sql_ref_by_season, { season.id => reused_ta_id.to_s })

      fixer.send(:prepare_team_affiliation_fallbacks)
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 0: Resolve missing destination TeamAffiliations')
      expect(sql).to include("reusing TeamAffiliation #{reused_ta_id}")
      expect(sql).to include("UPDATE team_affiliations SET team_id = #{new_team.id}, updated_at = NOW() WHERE id = #{reused_ta_id};")
    end

    it 'emits create SQL when fallback mode is create' do
      sql_var = "@dest_ta_#{season.id}"
      fixer.instance_variable_set(:@sql_log, [])
      fixer.instance_variable_set(:@dest_ta_resolution_by_season, { season.id => { mode: :create, ta_id: nil } })
      fixer.instance_variable_set(:@dest_ta_sql_ref_by_season, { season.id => sql_var })

      fixer.send(:prepare_team_affiliation_fallbacks)
      sql = fixer.sql_log.join("\n")
      expect(sql).to include('Step 0: Resolve missing destination TeamAffiliations')
      expect(sql).to include("creating missing TeamAffiliation for destination team #{new_team.id}")
      expect(sql).to include('INSERT INTO team_affiliations (team_id, season_id, name, created_at, updated_at)')
      expect(sql).to include("VALUES (#{new_team.id}, #{season.id}")
      expect(sql).to include("SET #{sql_var} = LAST_INSERT_ID();")
    end
  end

  describe 'multiple badges input' do
    # Find two badges from the same season and same (wrong) team
    let(:two_badges_same_season) do
      season_id = badge_with_mirs.season_id
      team_id = badge_with_mirs.team_id
      GogglesDb::Badge
        .where(season_id:, team_id:)
        .where.not(
          swimmer_id: GogglesDb::Badge
                        .where(season_id:, team_id: new_team.id)
                        .select(:swimmer_id)
        )
        .limit(2)
        .to_a
    end

    it 'accepts multiple badges' do
      skip('Not enough badges found for multi-badge test') if two_badges_same_season.size < 2

      fixer = described_class.new(badges: two_badges_same_season, new_team:)
      expect(fixer.badge_batch.count).to be >= 2
      two_badges_same_season.each do |badge|
        expect(fixer.badge_batch).to include(badge)
      end
    end
  end

  describe 'mixed-season badges input' do
    let(:multi_season_payload) do
      badges = GogglesDb::Badge.limit(400).to_a
      common_team_ids_cache = {}

      badges.combination(2).each do |badge_a, badge_b|
        next if badge_a.season_id == badge_b.season_id

        seasons_key = [badge_a.season_id, badge_b.season_id].sort
        common_team_ids_cache[seasons_key] ||= GogglesDb::TeamAffiliation
                                               .where(season_id: seasons_key)
                                               .group(:team_id)
                                               .having('COUNT(DISTINCT season_id) = 2')
                                               .pluck(:team_id)

        new_team = common_team_ids_cache[seasons_key]
                   .reject { |team_id| [badge_a.team_id, badge_b.team_id].include?(team_id) }
                   .find do |team_id|
          !GogglesDb::Badge.exists?(swimmer_id: badge_a.swimmer_id, season_id: badge_a.season_id, team_id:) &&
            !GogglesDb::Badge.exists?(swimmer_id: badge_b.swimmer_id, season_id: badge_b.season_id, team_id:)
        end
        next unless new_team

        return { badges: [badge_a, badge_b], new_team: GogglesDb::Team.find_by(id: new_team) }
      end
      nil
    end

    let(:missing_affiliation_payload) do
      badges = GogglesDb::Badge.limit(400).to_a

      badges.combination(2).each do |badge_a, badge_b|
        next if badge_a.season_id == badge_b.season_id

        destination_team = GogglesDb::TeamAffiliation
                           .where(season_id: badge_a.season_id)
                           .where.not(team_id: GogglesDb::TeamAffiliation.where(season_id: badge_b.season_id).select(:team_id))
                           .pluck(:team_id)
                           .find { |team_id| team_id != badge_a.team_id && team_id != badge_b.team_id }
        next unless destination_team

        return { badges: [badge_a, badge_b], new_team: GogglesDb::Team.find_by(id: destination_team) }
      end
      nil
    end

    it 'accepts badges from different seasons when destination team has affiliations for all seasons' do
      skip('No suitable mixed-season badge pair found in test DB') unless multi_season_payload

      fixer = described_class.new(
        badges: multi_season_payload[:badges],
        new_team: multi_season_payload[:new_team]
      )
      expect(fixer.seasons.map(&:id).uniq.size).to be > 1
      expect(fixer.dest_tas_by_season.keys).to match_array(fixer.seasons.map(&:id))
    end

    it 'accepts mixed-season payload even when destination team is missing one season affiliation' do
      skip('No mixed-season pair with missing destination affiliation found in test DB') unless missing_affiliation_payload

      fixer = described_class.new(
        badges: missing_affiliation_payload[:badges],
        new_team: missing_affiliation_payload[:new_team]
      )
      expect(fixer.seasons.map(&:id).uniq.size).to be > 1
      expect(fixer.dest_tas_by_season.keys).to match_array(fixer.seasons.map(&:id))
    end
  end
end
