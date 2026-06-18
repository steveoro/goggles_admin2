# frozen_string_literal: true

require 'rails_helper'

EXCLUDED_DIFF_COLUMNS = %w[id lock_version created_at updated_at].freeze

ENTITY_CONFIGS = [
  [GogglesDb::Meeting, :meeting],
  [GogglesDb::MeetingEvent, :meeting_event],
  [GogglesDb::MeetingProgram, :meeting_program],
  [GogglesDb::MeetingSession, :meeting_session],
  [GogglesDb::MeetingIndividualResult, :meeting_individual_result]
].freeze

ENTITY_LITERAL_COLUMNS = {
  GogglesDb::Meeting => { nil_column: 'home_team_id', boolean_column: 'confirmed' },
  GogglesDb::MeetingEvent => { nil_column: 'notes', boolean_column: 'out_of_race' },
  GogglesDb::MeetingProgram => { nil_column: 'standard_timing_id', boolean_column: 'autofilled' },
  GogglesDb::MeetingSession => { nil_column: 'notes', boolean_column: 'autofilled' },
  GogglesDb::MeetingIndividualResult => {
    nil_column: 'disqualification_code_type_id',
    boolean_column: 'disqualified'
  }
}.freeze

NULL_LITERALS = %w[null nil NULL Nil].freeze
FALSE_LITERALS = %w[false FALSE False].freeze
TRUE_LITERALS = %w[true TRUE True].freeze

RSpec.describe Import::Committers::LegacyPersistence do
  subject(:harness) { legacy_persistence_harness.new }

  let(:legacy_persistence_harness) do
    Class.new do
      include Import::Committers::LegacyPersistence
    end
  end

  def candidate_columns(model_class)
    model_class.column_names - EXCLUDED_DIFF_COLUMNS
  end

  def attribute_type_key(model_class, column)
    model_class.type_for_attribute(column.to_s).type
  end

  def values_differ_after_cast?(db_row, column, value)
    harness.send(:cast_for_compare, db_row, column, value) !=
      harness.send(:safe_read_attribute, db_row, column)
  end

  def alternate_value_for(db_row, column) # rubocop:disable Metrics/CyclomaticComplexity
    current = db_row.read_attribute(column)
    type = db_row.class.type_for_attribute(column.to_s)

    case type.type
    when :boolean then !current
    when :integer then current.to_i + 1
    when :string, :text then "#{current}_changed"
    when :decimal, :float then current.to_d + 1
    when :date then current + 1.day
    when :datetime then current + 1.hour
    when :time
      base = current || Time.zone.now
      base + 1.hour
    end
  end

  def pick_changed_columns(model_class, factory_row, existing_row, count: 3) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    candidates = candidate_columns(model_class).select do |column|
      next false unless factory_row.has_attribute?(column)

      factory_value = factory_row.read_attribute(column)
      next false if factory_value.blank?

      values_differ_after_cast?(existing_row, column, factory_value)
    end

    grouped = candidates.group_by { |column| attribute_type_key(model_class, column) }
    picked = []
    grouped.each_value do |columns|
      break if picked.size >= count

      picked << columns.sample
    end

    remaining = candidates - picked
    picked.concat(remaining.sample(count - picked.size)) if picked.size < count && remaining.any?

    picked
  end

  def resolve_changed_setup(model_class, existing_row, factory_name, count: 3)
    count.times do
      factory_row = FactoryBot.build(factory_name)
      changed_columns = pick_changed_columns(model_class, factory_row, existing_row, count: count)
      return [factory_row, changed_columns] if changed_columns.size >= count
    end

    factory_row = FactoryBot.build(factory_name)
    changed_columns = candidate_columns(model_class)
                      .select { |column| existing_row.has_attribute?(column) }
                      .group_by { |column| attribute_type_key(model_class, column) }
                      .values
                      .filter_map(&:sample)
                      .first(count)

    changed_columns.each do |column|
      factory_row.write_attribute(column, alternate_value_for(existing_row, column))
    end

    [factory_row, changed_columns]
  end

  def pick_unchanged_columns(model_class, _existing_row, changed_columns, count: 3)
    candidate_columns(model_class)
      .reject { |column| changed_columns.include?(column) }
      .sample(count)
  end

  def build_changed_attributes(existing_row, factory_row, changed_columns)
    attributes = existing_row.attributes.stringify_keys
    changed_columns.each do |column|
      attributes[column] = factory_row.read_attribute(column)
    end
    attributes
  end

  def attribute_equal_after_cast?(db_row, column, value)
    harness.send(:cast_for_compare, db_row, column, value) ==
      harness.send(:safe_read_attribute, db_row, column)
  end

  def sample_row(model_class, column:, value:)
    model_class.where(column => value).limit(100).sample
  end
  describe 'MeetingProgram standard_timing_id null literal' do
    it 'returns an empty hash when the database value is already nil' do
      row = sample_row(GogglesDb::MeetingProgram, column: 'standard_timing_id', value: nil)
      skip 'no meeting_program rows with nil standard_timing_id' if row.nil?

      expect(harness.changes_for_update(row, 'standard_timing_id' => 'null')).to be_empty
    end
  end

  ENTITY_CONFIGS.each do |model_class, factory_name|
    context "with #{model_class.name}" do
      let(:literal_columns) { ENTITY_LITERAL_COLUMNS.fetch(model_class) }
      let(:existing_row) { model_class.limit(300).sample }
      let(:changed_setup) { resolve_changed_setup(model_class, existing_row, factory_name) }
      let(:factory_row) { changed_setup.first }
      let(:changed_columns) { changed_setup.last }
      let(:unchanged_columns) { pick_unchanged_columns(model_class, existing_row, changed_columns) }
      let(:changed_attributes) { build_changed_attributes(existing_row, factory_row, changed_columns) }

      before(:each) do
        skip "no #{model_class.table_name} rows in database" if existing_row.nil?
        skip "could not pick 3 changed columns for #{model_class.name}" if changed_columns.size < 3
        skip "could not pick 3 unchanged columns for #{model_class.name}" if unchanged_columns.size < 3
      end

      describe '#cast_for_compare' do
        it 'detects changed attribute values as different from the database row' do
          changed_columns.each do |column|
            value = changed_attributes[column]

            expect(attribute_equal_after_cast?(existing_row, column, value)).to(
              be(false),
              "expected #{column}=#{value.inspect} to differ from DB value " \
              "#{existing_row.read_attribute(column).inspect}"
            )
          end
        end

        it 'treats unchanged attribute values as equal to the database row' do
          unchanged_columns.each do |column|
            value = changed_attributes[column]

            expect(attribute_equal_after_cast?(existing_row, column, value)).to(
              be(true),
              "expected #{column}=#{value.inspect} to match DB value " \
              "#{existing_row.read_attribute(column).inspect}"
            )
          end
        end

        it 'coerces null/nil string literals to nil before comparison' do
          column = literal_columns.fetch(:nil_column)

          NULL_LITERALS.each do |literal|
            expect(harness.send(:cast_for_compare, existing_row, column, literal)).to be_nil
          end
        end

        it 'coerces false string literals to false before comparison' do
          column = literal_columns.fetch(:boolean_column)

          FALSE_LITERALS.each do |literal|
            expect(harness.send(:cast_for_compare, existing_row, column, literal)).to be(false)
          end
        end

        it 'coerces true string literals to true before comparison' do
          column = literal_columns.fetch(:boolean_column)

          TRUE_LITERALS.each do |literal|
            expect(harness.send(:cast_for_compare, existing_row, column, literal)).to be(true)
          end
        end
      end

      describe '#changes_for_update' do
        it 'returns only attributes that differ from the database row' do
          diff = harness.changes_for_update(existing_row, changed_attributes)

          expect(diff.keys).to match_array(changed_columns)
        end

        it 'returns an empty hash when attributes match the database row' do
          diff = harness.changes_for_update(existing_row, existing_row.attributes)

          expect(diff).to be_empty
        end

        it 'returns an empty hash when a null string literal matches a nil database value' do
          column = literal_columns.fetch(:nil_column)
          row = sample_row(model_class, column: column, value: nil)
          skip "no #{model_class.table_name} rows with nil #{column}" if row.nil?

          NULL_LITERALS.each do |literal|
            expect(harness.changes_for_update(row, column => literal)).to be_empty
          end
        end

        it 'returns an empty hash when a false string literal matches a false database value' do
          column = literal_columns.fetch(:boolean_column)
          row = sample_row(model_class, column: column, value: false)
          skip "no #{model_class.table_name} rows with false #{column}" if row.nil?

          FALSE_LITERALS.each do |literal|
            expect(harness.changes_for_update(row, column => literal)).to be_empty
          end
        end

        it 'returns an empty hash when a true string literal matches a true database value' do
          column = literal_columns.fetch(:boolean_column)
          row = sample_row(model_class, column: column, value: true)
          skip "no #{model_class.table_name} rows with true #{column}" if row.nil?

          TRUE_LITERALS.each do |literal|
            expect(harness.changes_for_update(row, column => literal)).to be_empty
          end
        end
      end
    end
  end
end
