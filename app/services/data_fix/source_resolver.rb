# frozen_string_literal: true

module DataFix
  # SourceResolver: resolves the canonical LT4 working copy for a file_path
  # coming from the Data-Fix pipeline, materializing it from the original LT2
  # source when needed. Also owns the per-request memo of parsed source JSON
  # files and all source-file introspection helpers (layout, season, retry
  # flags, result-free detection, phase-path mapping).
  #
  # A new instance is meant to be used per request: the parsed-source memo
  # would otherwise leak stale JSON across writes performed by other requests.
  class SourceResolver
    def detect_season_from_pathname(file_path)
      season_id = File.dirname(file_path).split('/').last.to_i
      return GogglesDb::Season.find(season_id) if season_id.positive?

      SeasonDefaults.default_season
    end

    def detect_layout_type(file_path)
      return 4 if file_path.to_s.end_with?('-lt4.json')

      detect_layout_type_from_content(file_path)
    end

    # Content-based layout detection: scans head/tail chunks for the layoutType
    # field without parsing full JSON. Unlike #detect_layout_type, this ignores
    # the -lt4.json filename convention so mislabeled working copies can be found.
    def detect_layout_type_from_content(file_path)
      begin
        File.open(file_path, 'rb') do |f|
          chunk = f.read(64 * 1024)
          detected = detect_layout_type_in_chunk(chunk)
          return detected if detected

          if f.size > 64 * 1024
            f.seek(-64 * 1024, IO::SEEK_END)
            detected = detect_layout_type_in_chunk(f.read(64 * 1024))
            return detected if detected
          end
        end
      rescue StandardError
        # ignore
      end
      2
    end

    def detect_layout_type_in_chunk(chunk)
      return if chunk.blank?

      m = chunk.match(/"layoutType"\s*:\s*(\d+)/)
      m && m[1].to_i
    end

    # Resolve the canonical source used by phased v2 processing.
    # LT4 files are used as-is; LT2 files are mapped to sibling -lt4 working copies.
    # Existing -lt4 copies are reused. Missing -lt4 copies are regenerated from the
    # original LT2 source when available.
    # Result categories that don't resolve to a CategoryType of the target season
    # (e.g., FICR 'UNF' or '*' summary codes) are normalized in place.
    def resolve_working_source_path(file_path)
      source_path = resolve_source_path(file_path)
      return source_path if source_path.blank?

      working_path =
        if source_path.end_with?('-lt4.json') # Assume the suffix coincides with actual layoutType
          resolve_lt4_working_copy_path(source_path)
        elsif detect_layout_type(source_path) == 2
          resolve_lt2_source_to_working_copy(source_path)
        else
          source_path
        end
      normalize_lt4_result_categories(working_path)
      working_path
    rescue StandardError => e
      Rails.logger.error("[DataFix::SourceResolver] resolve_working_source_path failed: #{e.message}")
      resolve_source_path(file_path)
    end

    def resolve_lt4_working_copy_path(source_path)
      if File.exist?(source_path)
        # A -lt4.json working copy must hold LT4 data; if it actually contains
        # LT2 (e.g. a renamed legacy source), re-materialize it in place.
        return source_path unless detect_layout_type_from_content(source_path) == 2

        return materialize_lt4_in_place(source_path) || source_path
      end

      original_lt2_path = source_path.sub(/-lt4\.json\z/, '.json')
      if File.exist?(original_lt2_path) && detect_layout_type(original_lt2_path) == 2
        created_path = materialize_lt4_working_copy(
          lt2_source_path: original_lt2_path,
          lt4_source_path: source_path
        )
        return created_path if created_path.present?
      end

      Rails.logger.warn("[DataFix::SourceResolver] Missing LT4 working source: #{source_path}")
      source_path
    end

    # Rewrites an existing -lt4.json file that contains LT2 data into a proper
    # LT4 working copy, keeping a .orig.json backup of the previous content.
    def materialize_lt4_in_place(source_path)
      backup_path = next_backup_path_for(source_path)
      FileUtils.cp(source_path, backup_path)
      materialize_lt4_working_copy(lt2_source_path: source_path, lt4_source_path: source_path)
    end

    def next_backup_path_for(source_path)
      base = source_path.delete_suffix('.json')
      candidate = "#{base}.orig.json"
      return candidate unless File.exist?(candidate)

      index = 2
      index += 1 while File.exist?("#{base}.orig-#{index}.json")
      "#{base}.orig-#{index}.json"
    end

    def resolve_lt2_source_to_working_copy(source_path)
      lt4_source_path = source_path.sub(/\.json\z/, '-lt4.json')
      if File.exist?(lt4_source_path)
        # Reuse the existing working copy only if it really holds LT4 data;
        # an LT2 payload under the -lt4 name is re-materialized in place.
        return lt4_source_path unless detect_layout_type_from_content(lt4_source_path) == 2

        return materialize_lt4_in_place(lt4_source_path) || lt4_source_path
      end
      return source_path unless File.exist?(source_path)

      materialize_lt4_working_copy(
        lt2_source_path: source_path,
        lt4_source_path: lt4_source_path
      ) || source_path
    end

    # Rewrites LT4 result categories that don't resolve to a CategoryType defined
    # for the season encoded in the file path (e.g., FICR 'UNF'/'*' codes), using
    # the same CategoryComputer-backed logic as the manual recompute action.
    # Dependent phase files and temp rows are invalidated when the file changes.
    # No-ops when the file is not LT4, the season/meeting date can't be determined,
    # or every result category already resolves.
    def normalize_lt4_result_categories(source_path)
      return if source_path.blank? || !File.exist?(source_path)
      return unless detect_layout_type_from_content(source_path) == 4

      season_id = File.dirname(source_path).split('/').last.to_i
      return unless season_id.positive?

      season = GogglesDb::Season.find_by(id: season_id)
      return unless season

      data_hash = parsed_source_json(source_path)
      categories_cache = PdfResults::CategoriesCache.cached_for(season)
      return unless lt4_result_categories_need_normalization?(data_hash, categories_cache)

      raw_date = data_hash['dates'].to_s.split(',').first.presence || data_hash['meeting_date']
      meeting_date = raw_date.present? ? Date.parse(raw_date.to_s) : nil
      return if meeting_date.blank?

      result = DataFix::CategoryRecomputer.new(
        source_path: source_path,
        season: season,
        meeting_date: meeting_date,
        categories_cache: categories_cache
      ).call
      return if result[:backup_path].blank?

      invalidate_parsed_source_json(source_path)
      invalidated = invalidate_category_dependent_artifacts(source_path)
      Rails.logger.info(
        "[DataFix::SourceResolver] Normalized result categories in #{source_path} " \
        "(#{result[:result_categories_changed]} results, #{result[:swimmer_categories_changed]} swimmers; " \
        "backup=#{result[:backup_path]}; invalidated=#{invalidated.inspect})"
      )
    rescue StandardError => e
      Rails.logger.warn("[DataFix::SourceResolver] LT4 category normalization skipped for #{source_path}: #{e.message}")
      nil
    end

    # TRUE when any result category in the LT4 source does not resolve to a
    # CategoryType defined for the given season.
    def lt4_result_categories_need_normalization?(data_hash, categories_cache)
      Array(data_hash['events']).any? do |event|
        Array(event['results']).any? do |result|
          code = result['category'].to_s.strip.upcase
          code.present? && !categories_cache.key?(code)
        end
      end
    end

    # Per-request memo of parsed source JSON files. Several review actions read &
    # JSON.parse the same source file multiple times per request; sharing one hash
    # avoids the redundant parses. Invalidate explicitly wherever a source file is
    # rewritten within the same request (LT4 materialization, category recompute).
    def parsed_source_json(source_path)
      (@parsed_source_json ||= {})[source_path] ||= JSON.parse(File.read(source_path))
    end

    def invalidate_parsed_source_json(source_path)
      @parsed_source_json&.delete(source_path)
    end

    # TRUE when the source JSON carries no result rows at all (e.g. manifest-extracted
    # meeting-only files). Such sources can be committed as a bare meeting structure
    # (meeting + sessions + optional events) and updated by a later results pass.
    def source_result_free?(source_path)
      data_hash = parsed_source_json(source_path)
      return false unless data_hash.is_a?(Hash)

      return true if data_hash.dig('_meta', 'meeting_only') == true

      events = data_hash['events']
      return events.none? { |event| Array(event['results']).any? } if events.is_a?(Array)

      sections = data_hash['sections']
      return sections.none? { |section| Array(section['rows']).any? } if sections.is_a?(Array)

      false
    rescue StandardError => e
      Rails.logger.warn("[DataFix::SourceResolver] result-free detection failed for #{source_path}: #{e.message}")
      false
    end

    # Sets the `manifest` flag in the Phase 1 datafile so the committed Meeting row
    # is marked as manifest-only. Applies only when a NEW meeting will be created
    # (no meeting id selected); existing meetings keep their current flag.
    def mark_phase1_manifest_flag!(phase1_path)
      pfm = PhaseFileManager.new(phase1_path)
      data = pfm.data
      return if data['id'].present?

      data['manifest'] = true
      pfm.write!(data: data, meta: pfm.meta)
    end

    def materialize_lt4_working_copy(lt2_source_path:, lt4_source_path:)
      data_hash = parsed_source_json(lt2_source_path)
      normalized = Import::Adapters::Layout2To4.normalize(data_hash: data_hash)

      retry_needed = source_has_retry_section_in_hash?(data_hash)
      normalized_meta = normalized['_meta']
      normalized_meta = {} unless normalized_meta.is_a?(Hash)
      normalized_meta['retry_needed'] = retry_needed
      normalized['_meta'] = normalized_meta

      FileUtils.mkdir_p(File.dirname(lt4_source_path))
      File.write(lt4_source_path, JSON.pretty_generate(normalized))
      invalidate_parsed_source_json(lt4_source_path)
      Rails.logger.info("[DataFix::SourceResolver] LT2=>LT4 working copy created: #{lt4_source_path}")
      lt4_source_path
    rescue StandardError => e
      Rails.logger.error("[DataFix::SourceResolver] LT2=>LT4 materialization failed: #{e.message} (source: #{lt2_source_path})")
      nil
    end

    def default_phase_path_for(source_path, phase_num)
      dir = File.dirname(source_path)
      base = File.basename(source_path, File.extname(source_path))
      File.join(dir, "#{base}-phase#{phase_num}.json")
    end

    def source_has_retry_section?(source_path)
      data_hash = parsed_source_json(source_path)
      return true if source_has_retry_section_in_hash?(data_hash)
      return true if source_has_retry_meta_flag?(data_hash)

      lt2_source_path = paired_lt2_source_path(source_path)
      return false if lt2_source_path.blank?

      lt2_data_hash = parsed_source_json(lt2_source_path)
      source_has_retry_section_in_hash?(lt2_data_hash)
    rescue StandardError => e
      Rails.logger.warn("[DataFix::SourceResolver] retry-section detection failed for #{source_path}: #{e.message}")
      false
    end

    def source_has_retry_section_in_hash?(data_hash)
      return false unless data_hash.is_a?(Hash)

      Array(data_hash['sections']).any? { |sect| sect.is_a?(Hash) && sect.key?('retry') }
    end

    def source_has_retry_meta_flag?(data_hash)
      return false unless data_hash.is_a?(Hash)

      meta = data_hash['_meta']
      meta.is_a?(Hash) && meta['retry_needed'] == true
    end

    def paired_lt2_source_path(source_path)
      return nil if source_path.blank?
      return nil unless source_path.end_with?('-lt4.json')

      lt2_source_path = source_path.sub(/-lt4\.json\z/, '.json')
      File.exist?(lt2_source_path) ? lt2_source_path : nil
    end

    def sync_phase_retry_flag!(phase_path:, source_path:)
      retry_needed = source_has_retry_section?(source_path)
      return retry_needed unless File.exist?(phase_path)

      phase_payload = JSON.parse(File.read(phase_path))
      return retry_needed unless phase_payload.is_a?(Hash)

      phase_meta = phase_payload['_meta']
      phase_meta = {} unless phase_meta.is_a?(Hash)
      phase_meta['retry_needed'] = retry_needed
      phase_payload['_meta'] = phase_meta

      File.write(phase_path, JSON.pretty_generate(phase_payload))
      retry_needed
    rescue StandardError => e
      Rails.logger.warn("[DataFix::SourceResolver] retry flag sync failed for #{phase_path}: #{e.message}")
      retry_needed || false
    end

    # If file_path points to a phase file, resolve original source_path from its meta.
    def resolve_source_path(file_path)
      return file_path if file_path.blank?
      return file_path unless /-phase\d+\.json\z/.match?(file_path)

      pfm = PhaseFileManager.new(file_path)
      meta = pfm.meta
      meta['source_path'].presence || file_path
    rescue StandardError
      file_path
    end

    def source_meeting_date(source_path)
      source_data = parsed_source_json(source_path)
      raw_date = source_data['dates'].to_s.split(',').first.presence || source_data['meeting_date']
      Date.parse(raw_date.to_s).iso8601 if raw_date.present?
    rescue StandardError
      nil
    end

    def invalidate_category_dependent_artifacts(source_path)
      phase_paths = [3, 4, 5].map { |phase| default_phase_path_for(source_path, phase) }
      phase_paths.each { |path| FileUtils.rm_f(path) }

      tables = [
        GogglesDb::DataImportMeetingIndividualResult,
        GogglesDb::DataImportLap,
        GogglesDb::DataImportMeetingRelayResult,
        GogglesDb::DataImportMeetingRelaySwimmer,
        GogglesDb::DataImportRelayLap
      ]
      deleted_rows = tables.sum { |table| table.where(phase_file_path: source_path).delete_all }

      { phase_files: phase_paths, deleted_temp_rows: deleted_rows }
    end

    def category_recompute_summary(result)
      I18n.t(
        'data_import.messages.category_recompute_success',
        swimmers_processed: result[:swimmers_processed],
        swimmer_categories_changed: result[:swimmer_categories_changed],
        result_categories_changed: result[:result_categories_changed],
        skipped_categories: result[:skipped_categories].size,
        backup_path: result[:backup_path] || I18n.t('data_import.messages.category_recompute_no_backup')
      )
    end
  end
end
