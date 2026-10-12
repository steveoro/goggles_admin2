# frozen_string_literal: true

# rubocop:disable Rails/SkipsModelValidations
#
# Intentionally skips AR validations in the test setup: we need to create
# rows with stale coded names that the strategy is supposed to detect.

require 'rails_helper'

RSpec.describe Normalize::CodedNames do
  # == Helpers ===============================================================

  def build_meeting(options = {})
    meeting = FactoryBot.create(
      :meeting,
      description: options.fetch(:description),
      code: options.fetch(:code),
      season: options.fetch(:season),
      edition: options.fetch(:edition, 0),
      edition_type: options.fetch(:edition_type, GogglesDb::EditionType.none)
    )
    FactoryBot.create(:meeting_session, meeting:, swimming_pool: options[:pool]) if options[:pool]
    meeting
  end

  let(:city) { FactoryBot.create(:city, name: 'Napoli') }
  let(:pool) { FactoryBot.create(:swimming_pool, city:) }
  let(:fin_season) { FactoryBot.create(:season, season_type: GogglesDb::SeasonType.mas_fin) }

  # == #call =================================================================

  describe '#call (meetings)' do
    context 'with a meeting carrying a roman-edition code residue' do
      subject(:normalizer) { described_class.new.tap(&:call) }

      let!(:meeting) do
        build_meeting(description: 'XII Napoli Meeting', code: 'xiinapoli', pool:, season: fin_season)
      end

      it 'emits a single UPDATE combining code, edition & edition_type fixes' do
        sql = normalizer.sql_log.find { |line| line.include?("WHERE `id`=#{meeting.id}") }
        expect(sql).to include('UPDATE `meetings`')
        expect(sql).to include('`code`=\'napoli\'')
        expect(sql).to include('`edition`=12')
        expect(sql).to include("`edition_type_id`=#{GogglesDb::EditionType::ROMAN_ID}")
        expect(sql).to include('`updated_at`=NOW()')
      end

      it 'logs the change in the human-readable change_log' do
        expect(normalizer.change_log.join).to include("Meeting ID #{meeting.id}")
        expect(normalizer.change_log.join).to include("'xiinapoli' => 'napoli'")
      end

      it 'does NOT modify the local DB row' do
        expect(meeting.reload.code).to eq('xiinapoli')
        expect(meeting.edition).to eq(0)
      end
    end

    context 'with an already-normalized meeting' do
      let!(:meeting) do
        code = GogglesDb::Normalizers::CodedName.for_meeting('Trofeo del Mare', 'Napoli')
        build_meeting(description: 'Trofeo del Mare', code:, pool:, season: fin_season)
      end

      it 'emits no UPDATE for that row' do
        sql_log = described_class.new.tap(&:call).sql_log.join("\n")
        expect(sql_log).not_to include("WHERE `id`=#{meeting.id}")
      end
    end

    context 'with a meeting whose description normalizes to a blank code' do
      # A meeting with no swimming pool => no city => "Meeting" alone => ''
      let!(:meeting) do
        build_meeting(description: 'Meeting', code: 'some-code', pool: nil, season: fin_season)
      end

      it 'skips the row and warns instead of emitting a blank UPDATE' do
        normalizer = described_class.new.tap(&:call)
        expect(normalizer.sql_log.join("\n")).not_to include("WHERE `id`=#{meeting.id}")
        expect(normalizer.change_log.join).to match(/SKIPPED.*blank computed code/)
      end
    end

    context 'with a meeting whose computed code exceeds the column limit' do
      let!(:meeting) do
        build_meeting(description: 'XII Napoli Meeting', code: 'xiinapoli', pool:, season: fin_season)
      end

      before(:each) do
        allow(GogglesDb::Normalizers::CodedName).to receive(:for_meeting).and_return('x' * 51)
      end

      it 'skips the code change and warns instead of emitting a too-long UPDATE' do
        normalizer = described_class.new.tap(&:call)
        sql = normalizer.sql_log.find { |line| line.include?("WHERE `id`=#{meeting.id}") }
        expect(sql).not_to include('`code`=') if sql # edition-only UPDATE is fine
        expect(normalizer.change_log.join).to match(/SKIPPED.*too long/)
      end
    end
  end

  describe '#call (swimming pools)' do
    subject(:normalizer) { described_class.new.tap(&:call) }

    context 'with a pool having a stale nick_name' do
      let!(:stale_pool) { FactoryBot.create(:swimming_pool, city:, nick_name: 'totally-stale-nick') }
      let(:expected) do
        GogglesDb::Normalizers::CodedName.for_pool(stale_pool.name, city.name, stale_pool.pool_type.code)
      end

      it 'emits an UPDATE with the normalized nick_name' do
        sql = normalizer.sql_log.find { |line| line.include?("WHERE `id`=#{stale_pool.id}") }
        expect(sql).to include('UPDATE `swimming_pools`')
        expect(sql).to include("`nick_name`='#{expected}'")
      end

      it 'does NOT modify the local DB row' do
        expect(stale_pool.reload.nick_name).to eq('totally-stale-nick')
      end
    end

    context 'with a pool already having its normalized nick_name' do
      let!(:ok_pool) do
        pool = FactoryBot.create(:swimming_pool, city:)
        nick = GogglesDb::Normalizers::CodedName.for_pool(pool.name, city.name, pool.pool_type.code)
        pool.update_column(:nick_name, nick)
        pool
      end

      it 'emits no UPDATE for that row' do
        expect(normalizer.sql_log.join("\n")).not_to include("WHERE `id`=#{ok_pool.id}")
      end
    end

    context 'with a pool whose computed nick_name exceeds the column limit' do
      let!(:long_pool) { FactoryBot.create(:swimming_pool, city:, nick_name: 'totally-stale-nick') }

      before(:each) do
        allow(GogglesDb::Normalizers::CodedName).to receive(:for_pool).and_return('x' * 51)
      end

      it 'skips the row and warns instead of emitting a too-long UPDATE' do
        normalizer = described_class.new.tap(&:call)
        expect(normalizer.sql_log.join("\n")).not_to include("WHERE `id`=#{long_pool.id}")
        expect(normalizer.change_log.join).to match(/SKIPPED.*too long/)
      end
    end

    context 'when the computed nick_name already exists on another pool' do
      let!(:conflict_pool) { FactoryBot.create(:swimming_pool, city:) }

      before(:each) do
        nick = GogglesDb::Normalizers::CodedName.for_pool(conflict_pool.name, city.name, conflict_pool.pool_type.code)
        FactoryBot.create(:swimming_pool, city:, nick_name: nick)
        conflict_pool.update_column(:nick_name, 'some-other-nick')
      end

      it 'skips the row and reports the ID as a duplicate warning' do
        expect(normalizer.sql_log.join("\n")).not_to include("WHERE `id`=#{conflict_pool.id}")
        expect(normalizer.duplicate_pool_ids).to include(conflict_pool.id)
        expect(normalizer.change_log.join).to include('already exists')
      end
    end
  end

  # == Options & structure ===================================================

  describe 'limit option' do
    # NOTE: the test DB is seeded with fixture rows having lower PKs, so created
    # rows are never within the first N: assert on the scan counters instead.
    it 'processes only the first N rows of each domain' do
      normalizer = described_class.new(limit: 1).tap(&:call)
      expect(normalizer.stats[:meetings_scanned]).to eq(1)
      expect(normalizer.stats[:pools_scanned]).to eq(1)
    end
  end

  describe '#single_transaction_sql_log' do
    it 'wraps the statements in a single transaction' do
      build_meeting(description: 'XII Napoli Meeting', code: 'xiinapoli', pool:, season: fin_season)
      log = described_class.new.tap(&:call).single_transaction_sql_log
      expect(log.join("\n")).to include('START TRANSACTION;')
      expect(log.last).to include('COMMIT;')
    end
  end

  describe '#stats' do
    it 'reports scanned/updated counters' do
      build_meeting(description: 'XII Napoli Meeting', code: 'xiinapoli', pool:, season: fin_season)
      normalizer = described_class.new.tap(&:call)
      expect(normalizer.stats[:meetings_scanned]).to eq(GogglesDb::Meeting.count)
      expect(normalizer.stats[:meetings_updated]).to be >= 1
    end
  end
end

# rubocop:enable Rails/SkipsModelValidations
