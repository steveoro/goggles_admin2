# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::Badge do
  let(:season) { FactoryBot.create(:season) }
  let(:category_type) { FactoryBot.create(:category_type, season:) }
  let(:team_affiliation) { FactoryBot.create(:team_affiliation, season:) }
  let(:team) { team_affiliation.team }

  let(:dest_badge) { FactoryBot.create(:badge, season:, category_type:, team_affiliation:, team:) }
  let(:src_badge) { FactoryBot.create(:badge, season:, category_type:, team_affiliation:, team:) }

  describe '#initialize' do
    it 'raises ArgumentError when source is not a Badge' do
      expect { described_class.new(source: 'not a badge', dest: dest_badge) }
        .to raise_error(ArgumentError, /Invalid source Badge!/)
    end

    it 'raises ArgumentError when destination is not a Badge' do
      expect { described_class.new(source: src_badge, dest: 'not a badge') }
        .to raise_error(ArgumentError, /Invalid destination!/)
    end
  end

  describe '#prepare' do
    context 'with compatible source and destination badges' do
      subject(:merger) { described_class.new(source: src_badge, dest: dest_badge) }

      before(:each) { merger.prepare }

      it 'keeps the destination badge row and deletes the source badge row' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include('UPDATE badges SET')
        expect(sql).to include("WHERE id = #{dest_badge.id}")
        expect(sql).to include("DELETE FROM badges WHERE id=#{src_badge.id}")
      end

      it 'does not change the destination team, affiliation or category' do
        sql = merger.sql_log.join("\n")
        expect(sql).not_to include('team_id')
        expect(sql).not_to include('team_affiliation_id')
        expect(sql).not_to include('category_type_id')
      end
    end

    context 'when source and destination have different teams' do
      let(:other_team) { FactoryBot.create(:team) }
      let(:other_affiliation) { FactoryBot.create(:team_affiliation, team: other_team, season:) }

      before(:each) do
        src_badge.update!(team: other_team, team_affiliation: other_affiliation)
        src_badge.reload
      end

      it 'halts without an override' do
        merger = described_class.new(source: src_badge, dest: dest_badge)
        expect { merger.prepare }.to raise_error(RuntimeError, /Unrecoverable errors/)
        expect(merger.sql_log).to be_empty
      end

      it 'overwrites with source team when force is set' do
        force_merger = described_class.new(source: src_badge, dest: dest_badge, force: true)
        force_merger.prepare
        sql = force_merger.sql_log.join("\n")
        expect(sql).to include("team_id = #{src_badge.team_id}")
        expect(sql).to include("team_affiliation_id=#{src_badge.team_affiliation_id}")
      end

      it 'keeps destination team when keep_dest_team is set' do
        keep_merger = described_class.new(source: src_badge, dest: dest_badge, keep_dest_team: true)
        keep_merger.prepare
        sql = keep_merger.sql_log.join("\n")
        expect(sql).not_to include("team_id = #{src_badge.team_id}")
        expect(sql).not_to include("team_affiliation_id=#{src_badge.team_affiliation_id}")
      end
    end

    context 'when source and destination have different categories' do
      let(:other_category) do
        GogglesDb::CategoryType.where(season:).where.not(id: category_type.id).where(relay: false).first ||
          FactoryBot.create(:category_type, season:)
      end

      before(:each) do
        src_badge.update!(category_type: other_category)
        src_badge.reload
      end

      it 'halts without an override' do
        merger = described_class.new(source: src_badge, dest: dest_badge)
        expect { merger.prepare }.to raise_error(RuntimeError, /Unrecoverable errors/)
        expect(merger.sql_log).to be_empty
      end

      it 'overwrites with source category when force is set' do
        force_merger = described_class.new(source: src_badge, dest: dest_badge, force: true)
        force_merger.prepare
        sql = force_merger.sql_log.join("\n")
        expect(sql).to include("category_type_id=#{src_badge.category_type_id}")
      end

      it 'keeps destination category when keep_dest_category is set' do
        keep_merger = described_class.new(source: src_badge, dest: dest_badge, keep_dest_category: true)
        keep_merger.prepare
        sql = keep_merger.sql_log.join("\n")
        expect(sql).not_to include("category_type_id=#{src_badge.category_type_id}")
      end
    end

    context 'when keep_dest_columns is set' do
      let(:other_team) { FactoryBot.create(:team) }
      let(:other_affiliation) { FactoryBot.create(:team_affiliation, team: other_team, season:) }
      let(:other_category) do
        GogglesDb::CategoryType.where(season:).where.not(id: category_type.id).where(relay: false).first ||
          FactoryBot.create(:category_type, season:)
      end

      before(:each) do
        src_badge.update!(
          team: other_team,
          team_affiliation: other_affiliation,
          category_type: other_category
        )
        src_badge.reload
      end

      it 'keeps the destination team and category values' do
        merger = described_class.new(source: src_badge, dest: dest_badge, keep_dest_columns: true, force: true)
        merger.prepare
        sql = merger.sql_log.join("\n")
        expect(sql).not_to include("team_id = #{src_badge.team_id}")
        expect(sql).not_to include("team_affiliation_id=#{src_badge.team_affiliation_id}")
        expect(sql).not_to include("category_type_id=#{src_badge.category_type_id}")
      end
    end
  end

  describe '#single_transaction_sql_log' do
    subject(:merger) { described_class.new(source: src_badge, dest: dest_badge) }

    it 'wraps the sql_log with transaction statements' do
      merger.prepare
      log = merger.single_transaction_sql_log
      expect(log.join).to include('START TRANSACTION')
      expect(log.join).to include('COMMIT')
    end
  end
end
