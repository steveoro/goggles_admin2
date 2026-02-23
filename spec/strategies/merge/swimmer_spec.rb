# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Merge::Swimmer do
  # Use two existing swimmers for basic tests
  let(:source) { GogglesDb::Swimmer.find(142) }
  let(:dest)   { GogglesDb::Swimmer.find(23) }

  describe '#initialize' do
    context 'with valid arguments' do
      subject(:merger) { described_class.new(source:, dest:) }

      it 'creates an instance' do
        expect(merger).to be_a(described_class)
      end

      it 'creates an internal SwimmerChecker' do
        expect(merger.checker).to be_a(Merge::SwimmerChecker)
      end

      it 'decorates the source swimmer' do
        expect(merger.source).to respond_to(:display_label)
      end

      it 'decorates the destination swimmer' do
        expect(merger.dest).to respond_to(:display_label)
      end

      it 'initializes empty sql_log' do
        expect(merger.sql_log).to eq([])
      end

      it 'defaults force to false' do
        expect(merger.instance_variable_get(:@force)).to be false
      end
    end

    context 'with force: true' do
      subject(:merger) { described_class.new(source:, dest:, force: true) }

      it 'stores the force flag' do
        expect(merger.instance_variable_get(:@force)).to be true
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when source is not a Swimmer' do
        expect { described_class.new(source: 'not a swimmer', dest:) }
          .to raise_error(ArgumentError, /must be Swimmers/)
      end

      it 'raises ArgumentError when dest is not a Swimmer' do
        expect { described_class.new(source:, dest: 'not a swimmer') }
          .to raise_error(ArgumentError, /must be Swimmers/)
      end
    end
  end

  describe '#prepare' do
    context 'when the checker passes (no conflicts)' do
      subject(:merger) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

      let(:src_swimmer) { FactoryBot.create(:swimmer) }
      let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

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

      it 'includes swimmer-only link updates' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include("UPDATE individual_records SET updated_at=NOW(), swimmer_id=#{dest_swimmer.id}")
        expect(sql).to include("UPDATE users SET updated_at=NOW(), swimmer_id=#{dest_swimmer.id}")
      end

      it 'includes source swimmer deletion' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include("DELETE FROM swimmers WHERE id=#{src_swimmer.id}")
      end

      it 'includes destination column update' do
        sql = merger.sql_log.join("\n")
        expect(sql).to include("WHERE id=#{dest_swimmer.id}")
      end
    end

    context 'when the checker fails and force is false' do
      subject(:merger) { described_class.new(source:, dest: source) }

      before(:each) { merger.prepare }

      it 'does not populate sql_log' do
        expect(merger.sql_log).to be_empty
      end

      it 'has errors' do
        expect(merger.errors).not_to be_empty
      end
    end

    context 'when the checker fails and force is true' do
      subject(:merger) { described_class.new(source:, dest: source, force: true) }

      before(:each) { merger.prepare }

      it 'populates sql_log despite errors' do
        expect(merger.sql_log).not_to be_empty
      end

      it 'logs forced status' do
        expect(merger.log.join("\n")).to include('FORCED')
      end
    end
  end

  context 'with shared badges (FactoryBot data)' do
    subject(:merger) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

    let(:season) { GogglesDb::Season.find(192) }
    let(:category_type) { season.category_types.where(relay: false).first }
    let(:team) { FactoryBot.create(:team) }
    let(:ta) { FactoryBot.create(:team_affiliation, team:, season:) }
    let(:src_swimmer) { FactoryBot.create(:swimmer) }
    let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

    before(:each) do
      FactoryBot.create(:badge, swimmer: src_swimmer, team:, team_affiliation: ta,
                                season:, category_type:)
      FactoryBot.create(:badge, swimmer: dest_swimmer, team:, team_affiliation: ta,
                                season:, category_type:)
      merger.prepare
    end

    it 'uses Merge::Badge sub-merges for shared badges' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Shared badges (via Merge::Badge sub-merges)')
    end

    it 'includes badge merge output or warning' do
      sql = merger.sql_log.join("\n")
      expect(sql).to include('Merge Badge').or include('WARNING: Badge merge failed')
    end
  end

  describe '#log' do
    subject(:merger) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

    let(:src_swimmer) { FactoryBot.create(:swimmer) }
    let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

    it 'delegates to checker' do
      merger.prepare
      expect(merger.log).to eq(merger.checker.log)
    end
  end

  describe '#errors' do
    subject(:merger) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

    let(:src_swimmer) { FactoryBot.create(:swimmer) }
    let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

    it 'delegates to checker' do
      merger.prepare
      expect(merger.errors).to eq(merger.checker.errors)
    end
  end

  describe '#warnings' do
    subject(:merger) { described_class.new(source: src_swimmer, dest: dest_swimmer) }

    let(:src_swimmer) { FactoryBot.create(:swimmer) }
    let(:dest_swimmer) { FactoryBot.create(:swimmer, gender_type: src_swimmer.gender_type) }

    it 'delegates to checker' do
      merger.prepare
      expect(merger.warnings).to eq(merger.checker.warnings)
    end
  end
end
