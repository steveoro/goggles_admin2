# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'securerandom'

module DataFix
  class CategoryRecomputer # rubocop:disable Metrics/ClassLength, Style/Documentation
    class InvalidSource < StandardError; end

    attr_reader :source_path, :season, :meeting_date, :categories_cache

    def initialize(source_path:, season:, meeting_date:, categories_cache:, progress: nil)
      @source_path = source_path
      @season = season
      @meeting_date = meeting_date
      @categories_cache = categories_cache
      @progress = progress || ->(_message, _current, _total) {}
    end

    def call # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      source_data = JSON.parse(File.read(source_path))
      swimmers = source_data['swimmers']
      validate_source!(swimmers)
      swimmer_entries = source_swimmer_entries(swimmers)

      swimmer_index = {
        exact: {},
        normalized: Hash.new { |hash, key| hash[key] = [] }
      }
      stats = {
        swimmers_processed: 0,
        swimmer_categories_changed: 0,
        result_categories_changed: 0,
        unchanged_categories: 0,
        skipped_categories: []
      }

      swimmer_entries.each_with_index do |(swimmer, source_key), index|
        stats[:swimmers_processed] += 1
        @progress.call('Recomputing swimmer categories', index + 1, swimmer_entries.size)
        identity = swimmer_identity(swimmer, source_key:)
        category_code = compute_category_code(identity)

        if category_code.present?
          if swimmer['category'].to_s == category_code
            stats[:unchanged_categories] += 1
          else
            swimmer['category'] = category_code
            stats[:swimmer_categories_changed] += 1
          end
        else
          stats[:skipped_categories] << skip_reason(identity, 'swimmer')
        end

        index_swimmer(swimmer_index, identity, swimmer)
      end

      walk_results(source_data, swimmer_index, stats)
      return stats.merge(backup_path: nil, invalidated_artifacts: []) if stats[:swimmer_categories_changed].zero? && stats[:result_categories_changed].zero?

      backup_path = replace_source_atomically(source_data)
      stats.merge(backup_path:, invalidated_artifacts: [])
    end

    private

    def validate_source!(swimmers)
      return if (swimmers.is_a?(Array) || swimmers.is_a?(Hash)) && swimmers.present?

      raise InvalidSource, 'LT4 source must contain a non-empty swimmers array or dictionary'
    end

    def source_swimmer_entries(swimmers)
      return swimmers.map { |swimmer| [swimmer, swimmer['key']] } if swimmers.is_a?(Array)

      swimmers.map { |source_key, swimmer| [swimmer, source_key] }
    end

    def swimmer_identity(swimmer, source_key: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      key = (source_key || swimmer['key']).to_s
      parts = key.split('|')
      gender = swimmer['gender_type_code'] || swimmer['gender']
      last_name = swimmer['last_name'] || swimmer['lastName']
      first_name = swimmer['first_name'] || swimmer['firstName']
      year_of_birth = swimmer['year_of_birth'] || swimmer['year'] || swimmer['yob']

      if last_name.blank? || first_name.blank? || year_of_birth.blank?
        offset = parts.first.to_s.match?(/\A[MF]\z/i) ? 1 : 0
        last_name ||= parts[offset]
        first_name ||= parts[offset + 1]
        year_of_birth ||= parts[offset + 2]
        gender ||= parts.first if offset == 1
      end

      {
        key: key.presence,
        last_name: last_name.to_s,
        first_name: first_name.to_s,
        year_of_birth: year_of_birth.to_i,
        gender: normalize_gender(gender),
        normalized_key: normalized_identity(last_name, first_name, year_of_birth)
      }
    end

    def compute_category_code(identity)
      return nil unless identity[:year_of_birth].positive? && identity[:gender].present? && meeting_date.present?

      _category_id, category_code = Import::CategoryComputer.compute_category(
        year_of_birth: identity[:year_of_birth],
        gender_code: identity[:gender],
        meeting_date: meeting_date,
        season: season,
        categories_cache: categories_cache
      )
      category_code
    end

    def index_swimmer(index, identity, swimmer)
      index[:exact][identity[:key]] = swimmer if identity[:key].present?
      index[:normalized][identity[:normalized_key]] ||= []
      index[:normalized][identity[:normalized_key]] << swimmer if identity[:normalized_key].present?
    end

    def walk_results(node, swimmer_index, stats, relay_context: false) # rubocop:disable Metrics/CyclomaticComplexity
      case node
      when Array
        node.each { |child| walk_results(child, swimmer_index, stats, relay_context:) }
      when Hash
        current_relay = relay_context || node['relay'] == true
        update_result_category(node, swimmer_index, stats) if node['category'].present? && !current_relay && node['swimmer'].present?
        node.each_value { |child| walk_results(child, swimmer_index, stats, relay_context: current_relay) }
      end
    end

    def update_result_category(result, swimmer_index, stats)
      swimmer = find_swimmer(result['swimmer'], swimmer_index)
      unless swimmer
        stats[:skipped_categories] << { scope: 'result', swimmer: result['swimmer'], reason: 'unmatched_or_ambiguous_swimmer' }
        return
      end

      identity = swimmer_identity(swimmer)
      category_code = compute_category_code(identity)
      if category_code.blank?
        stats[:skipped_categories] << skip_reason(identity, 'result')
        return
      end

      if result['category'].to_s == category_code
        stats[:unchanged_categories] += 1
      else
        result['category'] = category_code
        stats[:result_categories_changed] += 1
      end
    end

    def find_swimmer(key, index)
      return index[:exact][key] if index[:exact].key?(key)

      normalized = normalized_identity_from_key(key)
      candidates = index[:normalized][normalized]
      candidates&.one? ? candidates.first : nil
    end

    def normalized_identity_from_key(key)
      parts = key.to_s.split('|')
      offset = parts.first.to_s.match?(/\A[MF]\z/i) ? 1 : 0
      normalized_identity(parts[offset], parts[offset + 1], parts[offset + 2])
    end

    def normalized_identity(last_name, first_name, year_of_birth)
      [last_name, first_name, year_of_birth].map { |value| normalize_text(value) }.join('|')
    end

    def normalize_text(value)
      I18n.transliterate(value.to_s).strip.squeeze(' ').upcase
    end

    def normalize_gender(value)
      code = value.to_s.strip.upcase
      return 'M' if code.start_with?('M')
      return 'F' if code.start_with?('F')
      return 'X' if code.start_with?('X')

      nil
    end

    def skip_reason(identity, scope)
      {
        scope: scope,
        swimmer: identity[:key],
        reason: 'missing_year_gender_or_meeting_date'
      }
    end

    def replace_source_atomically(source_data)
      temporary_path = "#{source_path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}"
      backup_path = next_backup_path
      source_moved = false

      begin
        File.write(temporary_path, JSON.pretty_generate(source_data))
        File.rename(source_path, backup_path)
        source_moved = true
        File.rename(temporary_path, source_path)
        backup_path
      rescue StandardError
        FileUtils.rm_f(temporary_path)
        FileUtils.mv(backup_path, source_path) if source_moved && !File.exist?(source_path) && File.exist?(backup_path)
        raise
      end
    end

    def next_backup_path
      base = source_path.delete_suffix('.json')
      candidate = "#{base}.orig.json"
      return candidate unless File.exist?(candidate)

      index = 2
      loop do
        candidate = "#{base}.orig-#{index}.json"
        return candidate unless File.exist?(candidate)

        index += 1
      end
    end
  end
end
