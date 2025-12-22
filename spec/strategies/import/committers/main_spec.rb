# frozen_string_literal: true

require 'rails_helper'
require 'bigdecimal'

RSpec.describe Import::Committers::Main do
  let(:season) do
    # Random FIN-type season from the last available ones:
    # (badges, affiliations and results may exist already for some swimmers, but not always)
    GogglesDb::Season.for_season_type(GogglesDb::SeasonType.mas_fin).last(5).sample
  end

  # Use a new empty fake season if needed:
  let(:new_fin_season) do
    FactoryBot.create(:season,
                      season_type_id: GogglesDb::SeasonType::MAS_FIN_ID,
                      edition_type_id: GogglesDb::EditionType::YEARLY_ID,
                      timing_type_id: GogglesDb::TimingType::AUTOMATIC_ID)
  end

  # Temp dummy source file base:
  let(:source_path) { Rails.root.join('spec/fixtures/import/sample_meeting.json').to_s }

  # Helper to generate phase paths from source
  def phase_path_for(source, phase_num)
    dir = File.dirname(source)
    base = File.basename(source, '.json')
    File.join(dir, "#{base}-phase#{phase_num}.json")
  end

  # Helper to write phase JSON files
  def write_phase_json(source, phase_num, data)
    path = phase_path_for(source, phase_num)
    content = { '_meta' => { 'generated_at' => Time.now.iso8601 }, 'data' => data }
    File.write(path, JSON.pretty_generate(content))
    path
  end

  # Helper to create committer with proper paths
  def create_committer(source)
    described_class.new(
      source_path: source,
      phase1_path: phase_path_for(source, 1),
      phase2_path: phase_path_for(source, 2),
      phase3_path: phase_path_for(source, 3),
      phase4_path: phase_path_for(source, 4),
      phase5_path: phase_path_for(source, 5)
    )
  end

  describe 'initialization' do
    it 'loads phase files when they exist' do
      Dir.mktmpdir do |tmp|
        src = File.join(tmp, 'test_meeting.json')
        File.write(src, '{}')

        # Create phase files
        write_phase_json(src, 1, { 'season_id' => season.id, 'meeting' => {}, 'sessions' => [] })
        write_phase_json(src, 2, { 'teams' => [], 'team_affiliations' => [] })

        committer = create_committer(src)
        committer.send(:load_phase_files!)

        expect(committer.instance_variable_get(:@phase1_data)).not_to be_nil
        expect(committer.instance_variable_get(:@phase2_data)).not_to be_nil
      end
    end

    it 'initializes stats hash' do
      Dir.mktmpdir do |tmp|
        src = File.join(tmp, 'test_meeting.json')
        File.write(src, '{}')

        committer = create_committer(src)
        stats = committer.stats

        expect(stats[:meetings_created]).to eq(0)
        expect(stats[:teams_created]).to eq(0)
        expect(stats[:swimmers_created]).to eq(0)
        expect(stats[:badges_created]).to eq(0)
        expect(stats[:events_created]).to eq(0)
        expect(stats[:errors]).to eq([])
      end
    end
  end

  # NOTE: commit_team_affiliation, commit_badge, commit_meeting_event methods
  # were refactored to dedicated committer classes. Tests for those are in their
  # respective spec files (team_affiliation_spec.rb, badge_spec.rb, meeting_event_spec.rb).
  #
  # The Main committer now delegates to these classes via commit_phase2_entities,
  # commit_phase3_entities, commit_phase4_entities methods.

  describe '#sql_log_content' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:src_path) { File.join(tmp_dir, 'test.json').tap { |p| File.write(p, '{}') } }
    let(:committer) { create_committer(src_path) }

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    it 'returns formatted SQL log as string' do
      # SQL log is an array that can be joined
      expect(committer.sql_log).to be_an(Array)
      expect(committer.sql_log_content).to be_a(String)
    end
  end

  describe 'error handling' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:src_path) { File.join(tmp_dir, 'test.json').tap { |p| File.write(p, '{}') } }
    let(:committer) { create_committer(src_path) }

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    it 'initializes with empty errors array' do
      expect(committer.stats[:errors]).to eq([])
    end

    it 'provides access to stats for error tracking' do
      expect(committer.stats).to be_a(Hash)
      expect(committer.stats).to have_key(:errors)
    end
  end

  # NOTE: Most normalization helpers were moved to dedicated committer classes.
  # Tests for those are in their respective spec files:
  # - team_spec.rb: normalize_team_attributes
  # - team_affiliation_spec.rb: normalize_team_affiliation_attributes
  # - swimmer_spec.rb: normalize_swimmer_attributes
  # - badge_spec.rb: normalize_badge_attributes
  # - calendar_spec.rb: commit_calendar, build_calendar_attributes
  # - meeting_individual_result_spec.rb: normalize_attributes
  # - lap_spec.rb: normalize_attributes

  describe 'normalization helpers (still in Main)' do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:src_path) { File.join(tmp_dir, 'test.json').tap { |p| File.write(p, '{}') } }
    let(:committer) { create_committer(src_path) }

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    describe '#normalize_swimming_pool_attributes' do
      it 'resolves pool type code, casts booleans, and strips unknown keys' do
        pool_type = GogglesDb::PoolType.first || FactoryBot.create(:pool_type)

        pool_hash = {
          'name' => 'Downtown Pool',
          'pool_type_code' => pool_type.code,
          'multiple_pools' => '1',
          'garden' => 'false',
          'unexpected' => 'value'
        }

        normalized = committer.send(:normalize_swimming_pool_attributes, pool_hash, city_id: 42)

        expect(normalized['pool_type_id']).to eq(pool_type.id)
        expect(normalized['multiple_pools']).to be(true)
        expect(normalized['garden']).to be(false)
        expect(normalized['city_id']).to eq(42)
        expect(normalized).not_to have_key('unexpected')
      end
    end

    describe '#normalize_meeting_event_attributes' do
      it 'resolves heat type code, casts flags, and sanitizes attributes' do
        heat_type = GogglesDb::HeatType.first || FactoryBot.create(:heat_type)

        event_hash = {
          'meeting_session_id' => 7,
          'event_type_id' => 3,
          'heat_type' => heat_type.code,
          'out_of_race' => 'false',
          'split_gender_start_list' => '1',
          'unexpected' => 'value'
        }

        normalized = committer.send(
          :normalize_meeting_event_attributes,
          event_hash,
          meeting_session_id: 7,
          event_type_id: 3
        )

        expect(normalized['heat_type_id']).to eq(heat_type.id)
        expect(normalized['out_of_race']).to be(false)
        expect(normalized['split_gender_start_list']).to be(true)
        expect(normalized['meeting_session_id']).to eq(7)
        expect(normalized['event_type_id']).to eq(3)
        expect(normalized).not_to have_key('unexpected')
      end
    end

    describe '#normalize_meeting_program_attributes' do
      it 'fills required foreign keys, casts booleans, and strips extras' do
        program_hash = {
          'out_of_race' => '0',
          'autofilled' => 'true',
          'unexpected' => 'value'
        }

        normalized = committer.send(
          :normalize_meeting_program_attributes,
          program_hash,
          meeting_event_id: 10,
          category_type_id: 20,
          gender_type_id: 30
        )

        expect(normalized['meeting_event_id']).to eq(10)
        expect(normalized['category_type_id']).to eq(20)
        expect(normalized['gender_type_id']).to eq(30)
        expect(normalized['out_of_race']).to be(false)
        expect(normalized['autofilled']).to be(true)
        expect(normalized).not_to have_key('unexpected')
      end
    end
  end

  describe 'relay category/gender auto-computation' do
    let(:season) { GogglesDb::Season.find(242) } # Use known season with relay categories
    let(:meeting) do
      GogglesDb::Meeting.joins(:season).where(seasons: { id: season.id }).first ||
        FactoryBot.create(:meeting, season: season, header_date: Date.new(2024, 12, 6))
    end
    let(:committer) do
      Dir.mktmpdir do |tmp|
        src = File.join(tmp, 'test.json')
        File.write(src, '{}')

        # Create phase files with swimmer data
        write_phase_json(src, 1, { 'season_id' => season.id, 'meeting' => { 'id' => meeting.id }, 'sessions' => [] })
        write_phase_json(src, 2, { 'teams' => [] })
        write_phase_json(src, 3, {
                           'swimmers' => [
                             { 'key' => 'M|ROSSI|Mario|1970', 'gender_type_code' => 'M', 'swimmer_id' => 1 },
                             { 'key' => 'M|BIANCHI|Luigi|1975', 'gender_type_code' => 'M', 'swimmer_id' => 2 },
                             { 'key' => 'F|VERDI|Anna|1980', 'gender_type_code' => 'F', 'swimmer_id' => 3 },
                             { 'key' => 'F|NERI|Sara|1985', 'gender_type_code' => 'F', 'swimmer_id' => 4 }
                           ]
                         })
        write_phase_json(src, 4, { 'sessions' => [] })
        write_phase_json(src, 5, { 'programs' => [] })

        c = create_committer(src)
        c.send(:load_phase_files!)

        # Set up internal state
        c.instance_variable_set(:@meeting, meeting)
        c.instance_variable_set(:@season_id, season.id)
        c.instance_variable_set(:@categories_cache, PdfResults::CategoriesCache.new(season))
        return c
      end
    end

    describe '#extract_yob_from_swimmer_key' do
      it 'extracts YOB from 4-token format (GENDER|LAST|FIRST|YEAR)' do
        result = committer.send(:extract_yob_from_swimmer_key, 'M|ROSSI|Mario|1970')
        expect(result).to eq(1970)
      end

      it 'extracts YOB from 3-token format (LAST|FIRST|YEAR)' do
        result = committer.send(:extract_yob_from_swimmer_key, 'ROSSI|Mario|1970')
        expect(result).to eq(1970)
      end

      it 'extracts YOB as last token regardless of format' do
        # YOB is always the last token in swimmer keys
        expect(committer.send(:extract_yob_from_swimmer_key, 'F|ABBRUSCATO Maria|F.|1957')).to eq(1957)
      end

      it 'returns nil for invalid YOB' do
        expect(committer.send(:extract_yob_from_swimmer_key, 'ROSSI|Mario|invalid')).to be_nil
        expect(committer.send(:extract_yob_from_swimmer_key, nil)).to be_nil
        expect(committer.send(:extract_yob_from_swimmer_key, '')).to be_nil
      end

      it 'returns nil for out-of-range YOB' do
        expect(committer.send(:extract_yob_from_swimmer_key, 'ROSSI|Mario|1800')).to be_nil
        expect(committer.send(:extract_yob_from_swimmer_key, 'ROSSI|Mario|2200')).to be_nil
      end

      it 'returns nil for keys with less than 3 tokens' do
        expect(committer.send(:extract_yob_from_swimmer_key, 'ROSSI|Mario')).to be_nil
      end
    end

    describe '#extract_gender_from_swimmer_key' do
      it 'extracts gender from 4-token format (GENDER|LAST|FIRST|YEAR)' do
        expect(committer.send(:extract_gender_from_swimmer_key, 'M|ROSSI|Mario|1970')).to eq('M')
        expect(committer.send(:extract_gender_from_swimmer_key, 'F|VERDI|Anna|1980')).to eq('F')
      end

      it 'returns nil for 3-token format (no gender prefix)' do
        expect(committer.send(:extract_gender_from_swimmer_key, 'ROSSI|Mario|1970')).to be_nil
      end

      it 'returns nil for invalid gender code' do
        expect(committer.send(:extract_gender_from_swimmer_key, 'X|ROSSI|Mario|1970')).to be_nil
      end

      it 'returns nil for blank input' do
        expect(committer.send(:extract_gender_from_swimmer_key, nil)).to be_nil
        expect(committer.send(:extract_gender_from_swimmer_key, '')).to be_nil
      end
    end

    describe '#normalize_to_partial_key' do
      it 'normalizes 4-token format to partial key (strips gender)' do
        result = committer.send(:normalize_to_partial_key, 'M|ROSSI|Mario|1970')
        expect(result).to eq('|ROSSI|Mario|1970')
      end

      it 'normalizes 3-token format to partial key' do
        result = committer.send(:normalize_to_partial_key, 'ROSSI|Mario|1970')
        expect(result).to eq('|ROSSI|Mario|1970')
      end

      it 'returns nil for blank input' do
        expect(committer.send(:normalize_to_partial_key, nil)).to be_nil
        expect(committer.send(:normalize_to_partial_key, '')).to be_nil
      end
    end

    describe '#normalize_gender_code' do
      it 'normalizes male codes' do
        expect(committer.send(:normalize_gender_code, 'M')).to eq('M')
        expect(committer.send(:normalize_gender_code, 'Male')).to eq('M')
        expect(committer.send(:normalize_gender_code, 'MASCHIO')).to eq('M')
      end

      it 'normalizes female codes' do
        expect(committer.send(:normalize_gender_code, 'F')).to eq('F')
        expect(committer.send(:normalize_gender_code, 'Female')).to eq('F')
        expect(committer.send(:normalize_gender_code, 'FEMMINA')).to eq('F')
      end

      it 'returns nil for unknown codes' do
        expect(committer.send(:normalize_gender_code, 'X')).to be_nil
        expect(committer.send(:normalize_gender_code, nil)).to be_nil
        expect(committer.send(:normalize_gender_code, '')).to be_nil
      end
    end

    describe '#lookup_swimmer_gender_from_phase3' do
      it 'finds gender by exact key match' do
        result = committer.send(:lookup_swimmer_gender_from_phase3, 'M|ROSSI|Mario|1970')
        expect(result).to eq('M')
      end

      it 'finds gender by partial key match' do
        # The phase3 has 'M|ROSSI|Mario|1970', should match partial key from 3-token format
        result = committer.send(:lookup_swimmer_gender_from_phase3, 'ROSSI|Mario|1970')
        expect(result).to eq('M')
      end

      it 'returns nil for unknown swimmer' do
        result = committer.send(:lookup_swimmer_gender_from_phase3, 'UNKNOWN|Person|1990')
        expect(result).to be_nil
      end
    end

    describe '#compute_relay_category_from_swimmers' do
      context 'when MRS data is available' do
        before(:each) do
          # Create test MRR with 4 swimmers
          @mrr = GogglesDb::DataImportMeetingRelayResult.create!(
            import_key: 'test-mrr-1',
            meeting_program_key: '1-4X50SL-N/A-X',
            phase_file_path: '/tmp/test.json',
            rank: 1,
            minutes: 1, seconds: 45, hundredths: 0
          )

          # Create 4 relay swimmers with YOBs (ages ~54, 49, 44, 39 = 186 total at 2024)
          [
            { order: 1, key: 'M|ROSSI|Mario|1970' },
            { order: 2, key: 'M|BIANCHI|Luigi|1975' },
            { order: 3, key: 'F|VERDI|Anna|1980' },
            { order: 4, key: 'F|NERI|Sara|1985' }
          ].each do |swimmer_data|
            GogglesDb::DataImportMeetingRelaySwimmer.create!(
              import_key: "mrs#{swimmer_data[:order]}-#{@mrr.import_key}-#{swimmer_data[:key]}",
              parent_import_key: @mrr.import_key,
              phase_file_path: '/tmp/test.json',
              relay_order: swimmer_data[:order],
              swimmer_key: swimmer_data[:key],
              minutes: 0, seconds: 25, hundredths: 0
            )
          end
        end

        after(:each) do
          GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: @mrr.import_key).destroy_all
          @mrr.destroy
        end

        it 'computes relay category from swimmer ages' do
          # Ages at 2024: 54 + 49 + 44 + 39 = 186
          result = committer.send(:compute_relay_category_from_swimmers, '1-4X50SL-N/A-X')
          expect(result).to be_a(GogglesDb::CategoryType)
          expect(result.relay?).to be true
          # Should match a relay category with age range containing 186
          expect(result.age_begin..result.age_end).to cover(186)
        end
      end

      context 'when no MRS data is available' do
        it 'returns nil' do
          result = committer.send(:compute_relay_category_from_swimmers, '99-4X50SL-N/A-X')
          expect(result).to be_nil
        end
      end

      context 'when meeting is not set' do
        it 'returns nil' do
          committer.instance_variable_set(:@meeting, nil)
          result = committer.send(:compute_relay_category_from_swimmers, '1-4X50SL-N/A-X')
          expect(result).to be_nil
        end
      end
    end

    describe '#compute_relay_gender_from_swimmers' do
      context 'with all-male relay' do
        before(:each) do
          @mrr = GogglesDb::DataImportMeetingRelayResult.create!(
            import_key: 'test-mrr-male',
            meeting_program_key: '1-4X50SL-M100-M',
            phase_file_path: '/tmp/test.json',
            rank: 1,
            minutes: 1, seconds: 45, hundredths: 0
          )

          4.times do |i|
            GogglesDb::DataImportMeetingRelaySwimmer.create!(
              import_key: "mrs#{i + 1}-#{@mrr.import_key}",
              parent_import_key: @mrr.import_key,
              phase_file_path: '/tmp/test.json',
              relay_order: i + 1,
              swimmer_key: "M|SWIMMER#{i}|Name|#{1970 + (i * 5)}",
              minutes: 0, seconds: 25, hundredths: 0
            )
          end
        end

        after(:each) do
          GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: @mrr.import_key).destroy_all
          @mrr.destroy
        end

        it 'returns M for all-male relay' do
          result = committer.send(:compute_relay_gender_from_swimmers, '1-4X50SL-M100-M')
          expect(result).to eq('M')
        end
      end

      context 'with all-female relay' do
        before(:each) do
          @mrr = GogglesDb::DataImportMeetingRelayResult.create!(
            import_key: 'test-mrr-female',
            meeting_program_key: '1-4X50SL-M100-F',
            phase_file_path: '/tmp/test.json',
            rank: 1,
            minutes: 1, seconds: 45, hundredths: 0
          )

          4.times do |i|
            GogglesDb::DataImportMeetingRelaySwimmer.create!(
              import_key: "mrs#{i + 1}-#{@mrr.import_key}",
              parent_import_key: @mrr.import_key,
              phase_file_path: '/tmp/test.json',
              relay_order: i + 1,
              swimmer_key: "F|SWIMMER#{i}|Name|#{1970 + (i * 5)}",
              minutes: 0, seconds: 25, hundredths: 0
            )
          end
        end

        after(:each) do
          GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: @mrr.import_key).destroy_all
          @mrr.destroy
        end

        it 'returns F for all-female relay' do
          result = committer.send(:compute_relay_gender_from_swimmers, '1-4X50SL-M100-F')
          expect(result).to eq('F')
        end
      end

      context 'with mixed relay' do
        before(:each) do
          @mrr = GogglesDb::DataImportMeetingRelayResult.create!(
            import_key: 'test-mrr-mixed',
            meeting_program_key: '1-4X50SL-N/A-X',
            phase_file_path: '/tmp/test.json',
            rank: 1,
            minutes: 1, seconds: 45, hundredths: 0
          )

          # 2 male + 2 female swimmers
          [
            { order: 1, key: 'M|ROSSI|Mario|1970' },
            { order: 2, key: 'M|BIANCHI|Luigi|1975' },
            { order: 3, key: 'F|VERDI|Anna|1980' },
            { order: 4, key: 'F|NERI|Sara|1985' }
          ].each do |swimmer_data|
            GogglesDb::DataImportMeetingRelaySwimmer.create!(
              import_key: "mrs#{swimmer_data[:order]}-#{@mrr.import_key}",
              parent_import_key: @mrr.import_key,
              phase_file_path: '/tmp/test.json',
              relay_order: swimmer_data[:order],
              swimmer_key: swimmer_data[:key],
              minutes: 0, seconds: 25, hundredths: 0
            )
          end
        end

        after(:each) do
          GogglesDb::DataImportMeetingRelaySwimmer.where(parent_import_key: @mrr.import_key).destroy_all
          @mrr.destroy
        end

        it 'returns X for mixed relay' do
          result = committer.send(:compute_relay_gender_from_swimmers, '1-4X50SL-N/A-X')
          expect(result).to eq('X')
        end
      end

      context 'when no MRS data is available' do
        it 'returns nil' do
          result = committer.send(:compute_relay_gender_from_swimmers, '99-4X50SL-N/A-X')
          expect(result).to be_nil
        end
      end
    end
  end
end
