# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::Team do
  # Use two existing teams for basic tests (no swimmer overlap in test DB)
  let(:source) { GogglesDb::Team.find(1) }
  let(:dest)   { GogglesDb::Team.find(2) }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:merger) { described_class.new(source:, dest:) }

      it 'creates an instance' do
        expect(merger).to be_a(described_class)
      end

      it 'creates an internal TeamChecker' do
        expect(merger.checker).to be_a(Merge::TeamChecker)
      end

      it 'decorates the source team' do
        expect(merger.source).to respond_to(:display_label)
      end

      it 'decorates the destination team' do
        expect(merger.dest).to respond_to(:display_label)
      end

      it 'initializes empty sql_log' do
        expect(merger.sql_log).to eq([])
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when source is not a Team' do
        expect { described_class.new(source: 'not a team', dest:) }
          .to raise_error(ArgumentError, /must be Teams/)
      end

      it 'raises ArgumentError when dest is not a Team' do
        expect { described_class.new(source:, dest: 'not a team') }
          .to raise_error(ArgumentError, /must be Teams/)
      end
    end
  end

  describe '#prepare' do
    subject(:merger) { described_class.new(source:, dest:) }

    before(:each) { merger.prepare }

    it 'populates sql_log' do
      expect(merger.sql_log).not_to be_empty
    end

    it 'wraps output in a single transaction' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('SET AUTOCOMMIT = 0')
      expect(sql).to include('START TRANSACTION')
      expect(sql).to include('COMMIT')
    end

    it 'includes reservation cleanup SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('DELETE FROM meeting_event_reservations')
      expect(sql).to include('DELETE FROM meeting_relay_reservations')
      expect(sql).to include('DELETE FROM meeting_reservations')
    end

    it 'includes team-only update SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include("UPDATE computed_season_rankings SET updated_at=NOW(), team_id=#{dest.id}")
      expect(sql).to include("UPDATE goggle_cups SET updated_at=NOW(), team_id=#{dest.id}")
      expect(sql).to include("UPDATE laps SET updated_at=NOW(), team_id=#{dest.id}")
      expect(sql).to include("UPDATE relay_laps SET updated_at=NOW(), team_id=#{dest.id}")
    end

    it 'includes individual_records update SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include("UPDATE individual_records SET updated_at=NOW(), team_id=#{dest.id}")
    end

    it 'includes destination team column update SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('UPDATE teams SET updated_at=NOW()')
      expect(sql).to include("WHERE id=#{dest.id}")
    end

    it 'includes source team deletion SQL' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include("DELETE FROM team_aliases WHERE team_id=#{source.id}")
      expect(sql).to include("DELETE FROM teams WHERE id=#{source.id}")
    end

    it 'does not allow a second run' do
      log_size = merger.sql_log.size
      merger.prepare
      expect(merger.sql_log.size).to eq(log_size)
    end

    context 'with skip_columns: true' do
      subject(:merger) { described_class.new(source:, dest:, skip_columns: true) }

      before(:each) { merger.prepare }

      it 'includes name_variations in destination update' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include('name_variations=')
      end

      it 'does not include raw name= override' do
        sql = merger.sql_log.join("\n")
        expect(sql).not_to include("name=\"#{source.name}\"")
      end
    end
  end

  # Use FactoryBot to create a shared-swimmer scenario (test DB has no natural ones)
  context 'with shared swimmers (FactoryBot data)' do
    subject(:merger) { described_class.new(source: src_team, dest: dest_team) }

    let(:season) { GogglesDb::Season.find(192) }
    let(:category_type) { season.category_types.where(relay: false).first }
    let(:src_ta) { FactoryBot.create(:team_affiliation, season:) }
    let(:dest_ta) { FactoryBot.create(:team_affiliation, season:) }
    let(:src_team) { src_ta.team }
    let(:dest_team) { dest_ta.team }
    let(:swimmer) { GogglesDb::Swimmer.limit(200).sample }

    before(:each) do
      FactoryBot.create(:badge, swimmer:, team: src_team, team_affiliation: src_ta,
                                season:, category_type:)
      FactoryBot.create(:badge, swimmer:, team: dest_team, team_affiliation: dest_ta,
                                season:, category_type:)
      merger.prepare
    end

    it 'includes badge sub-merge header' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Badge sub-merges')
    end

    it 'includes badge merge output or warning for each shared couple' do
      sql = merger.sql_log.join("\n")
      # Either the badge merge succeeded (Merge Badge comment) or failed gracefully (WARNING)
      expect(sql).to include('Merge Badge').or include('WARNING: Badge merge failed')
    end
  end

  describe '#log' do
    subject(:merger) { described_class.new(source:, dest:) }

    it 'delegates to checker' do
      merger.prepare
      expect(merger.log).to eq(merger.checker.log)
    end
  end
end
