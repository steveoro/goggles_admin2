# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::CategoryCloner, type: :strategy do
  describe '#initialize' do
    context 'with valid seasons,' do
      subject(:cloner) { described_class.new(src_season:, dest_season:) }

      let(:src_season) { GogglesDb::Season.last(300).sample }
      let(:dest_season) { GogglesDb::Season.last(300).sample }

      it 'creates a new instance' do
        expect(cloner).to be_a(described_class)
      end

      it 'has empty sql_log, log, and errors' do
        expect(cloner.sql_log).to be_empty
        expect(cloner.log).to be_empty
        expect(cloner.errors).to be_empty
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#prepare' do
    context 'with valid but different seasons,' do
      let(:src_season) { FactoryBot.create(:season) }
      let(:dest_season) { FactoryBot.create(:season) }

      before(:each) do
        FactoryBot.create(:category_type, season: src_season, code: 'M25', relay: false)
        FactoryBot.create(:category_type, season: src_season, code: 'M30', relay: false)
        FactoryBot.create(:category_type, season: src_season, code: 'M35', relay: true)
      end

      context 'when dest has no existing categories,' do
        subject(:cloner) { described_class.new(src_season:, dest_season:) }

        before(:each) { cloner.prepare }

        it 'generates INSERT statements for all source categories' do
          insert_count = cloner.sql_log.count { |s| s.include?('INSERT INTO') }
          expect(insert_count).to eq(3)
        end

        it 'wraps the SQL in a transaction' do
          joined = cloner.sql_log.join("\n")
          expect(joined).to include('SET AUTOCOMMIT = 0')
          expect(joined).to include('START TRANSACTION')
          expect(joined).to include('COMMIT')
        end

        it 'logs the correct counts' do
          expect(cloner.log.join).to include('INSERTs prepared: 3')
          expect(cloner.log.join).to include('Skipped (already in dest): 0')
        end

        it 'uses NOW() for timestamps' do
          insert_sql = cloner.sql_log.find { |s| s.include?('INSERT INTO') }
          expect(insert_sql).to include('NOW(), NOW()')
        end

        it 'does not include the id column in INSERTs' do
          insert_sql = cloner.sql_log.find { |s| s.include?('INSERT INTO') }
          expect(insert_sql).not_to include('`id`')
        end

        it 'sets season_id to the dest season' do
          insert_sql = cloner.sql_log.find { |s| s.include?('INSERT INTO') }
          expect(insert_sql).to include(dest_season.id.to_s)
          expect(insert_sql).not_to include("`#{src_season.id}`")
        end

        it 'does not add errors' do
          expect(cloner.errors).to be_empty
        end
      end

      context 'when dest already has some matching categories,' do
        subject(:cloner) { described_class.new(src_season:, dest_season:) }

        before(:each) do
          FactoryBot.create(:category_type, season: dest_season, code: 'M25', relay: false)
          cloner.prepare
        end

        it 'skips categories that already exist in dest (matched by code + relay)' do
          insert_count = cloner.sql_log.count { |s| s.include?('INSERT INTO') }
          expect(insert_count).to eq(2) # M30 + M35(relay), M25 skipped
        end

        it 'logs the skip count' do
          expect(cloner.log.join).to include('Skipped (already in dest): 1')
        end
      end

      context 'when dest has a category with same code but different relay flag,' do
        subject(:cloner) { described_class.new(src_season:, dest_season:) }

        before(:each) do
          # Same code 'M35' but relay: false in dest, while src has relay: true
          FactoryBot.create(:category_type, season: dest_season, code: 'M35', relay: false)
          cloner.prepare
        end

        it 'does not skip the category (relay flag differs)' do
          insert_count = cloner.sql_log.count { |s| s.include?('INSERT INTO') }
          expect(insert_count).to eq(3) # all 3 inserted, none skipped
        end
      end
    end

    context 'with remove_codes,' do
      let(:src_season) { FactoryBot.create(:season) }
      let(:dest_season) { FactoryBot.create(:season) }

      before(:each) do
        FactoryBot.create(:category_type, season: src_season, code: 'M25', relay: false)
        FactoryBot.create(:category_type, season: dest_season, code: 'U25', relay: false)
        FactoryBot.create(:category_type, season: dest_season, code: 'U30', relay: false)
      end

      context 'when remove_codes is an array' do
        subject(:cloner) { described_class.new(src_season:, dest_season:, remove_codes: ['U25']) }

        before(:each) { cloner.prepare }

        it 'generates a DELETE statement for the matching category' do
          delete_count = cloner.sql_log.count { |s| s.include?('DELETE FROM') }
          expect(delete_count).to eq(1)
        end

        it 'logs the delete count' do
          expect(cloner.log.join).to include('DELETEs prepared: 1')
          expect(cloner.log.join).to include('U25')
        end
      end

      context 'when remove_codes is a comma-separated string' do
        subject(:cloner) { described_class.new(src_season:, dest_season:, remove_codes: 'U25,U30') }

        before(:each) { cloner.prepare }

        it 'generates DELETE statements for all matching categories' do
          delete_count = cloner.sql_log.count { |s| s.include?('DELETE FROM') }
          expect(delete_count).to eq(2)
        end
      end

      context 'when remove_codes is nil' do
        subject(:cloner) { described_class.new(src_season:, dest_season:) }

        before(:each) { cloner.prepare }

        it 'does not generate any DELETE statements' do
          delete_count = cloner.sql_log.count { |s| s.include?('DELETE FROM') }
          expect(delete_count).to eq(0)
        end
      end
    end

    context 'with invalid parameters,' do
      context 'when src_season is not a Season' do
        subject(:cloner) { described_class.new(src_season: 'not-a-season', dest_season: FactoryBot.create(:season)) }

        before(:each) { cloner.prepare }

        it 'adds an error' do
          expect(cloner.errors).to include('Source season must be a valid GogglesDb::Season')
        end

        it 'does not generate any SQL' do
          expect(cloner.sql_log).to be_empty
        end

        it 'does not add errors for dest' do
          expect(cloner.errors).not_to include('Destination season must be a valid GogglesDb::Season')
        end
      end

      context 'when dest_season is not a Season' do
        subject(:cloner) { described_class.new(src_season: FactoryBot.create(:season), dest_season: nil) }

        before(:each) { cloner.prepare }

        it 'adds an error' do
          expect(cloner.errors).to include('Destination season must be a valid GogglesDb::Season')
        end

        it 'does not add errors for src' do
          expect(cloner.errors).not_to include('Source season must be a valid GogglesDb::Season')
        end
      end

      context 'when src and dest are the same season' do
        subject(:cloner) { described_class.new(src_season: season, dest_season: season) }

        let(:season) { FactoryBot.create(:season) }

        before(:each) { cloner.prepare }

        it 'adds an error' do
          expect(cloner.errors).to include('Source and destination seasons must be different')
        end

        it 'does not add other errors' do
          expect(cloner.errors).to include('Source and destination seasons must be different')
          expect(cloner.errors.length).to eq(1)
        end
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
