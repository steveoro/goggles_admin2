# frozen_string_literal: true

require 'digest'
require 'securerandom'

module DataFix
  #
  # = DataFix::Pipeline
  #
  # The Data-Fix phase orchestration of ONE source (its canonical LT4 working copy, see DataFix::SourceResolver),
  # shared by the review actions of the per-phase controllers (and, from phase 10, by the prepare jobs):
  #
  # - builds (#build_phase!, #prepare!) through the five Pipeline::Recipes, under a lease (Ops::PipelineSource);
  # - edit markers in the phase file '_meta' (authoritative, mirrored in Ops::PhaseVerdict):
  #   '_meta.built' = { 'by' => 'auto'|'operator'|'adopted', 'at', 'digest', 'inputs', 'db_generation' } and
  #   '_meta.operator_edit' = { 'at', 'user_id', 'actions' }; see #edited?, #mark_edited!, #restamp!;
  # - staleness (#stale?) from the input projections of Pipeline::Digests;
  # - verdicts (#verdict, #summary), cached in Ops::PhaseVerdict by a fingerprint of the files they read;
  # - the only path that deletes phase files (#invalidate!), which never deletes an edited phase without +force+.
  #
  # Operator edits win: an automatic build (+force: false+) never rewrites an edited phase, and a phase file
  # without a 'built' stamp (any file that existed when this shipped) is adopted as edited.
  #
  # == Usage
  #   pipeline = DataFix::Pipeline.for(source_path, progress: Import::Progress::Cable.new, actor: :operator)
  #   pipeline.build_phase!(2, force: true)   # => DataFix::Verdict
  #   pipeline.summary.stage                   # => 'needs_review'
  #
  class Pipeline
    # Build of an edited phase without force.
    class EditedPhaseError < StandardError; end
    # An upstream phase file is missing (e.g. phase 3 without phase 1/2).
    class MissingUpstreamError < StandardError; end
    # Another request/job is building this source.
    class LeaseBusyError < StandardError; end

    PHASES = (1..5)
    ACTORS = %i[operator auto].freeze
    UPSTREAMS = { 1 => [], 2 => [], 3 => [1, 2], 4 => [1], 5 => [1, 2, 3, 4] }.freeze
    MAX_EDIT_ACTIONS = 20
    DB_GENERATION_KEY = 'data_fix.db_generation'
    # Bump when a verdict checker changes: cached verdicts are recomputed.
    VERDICT_VERSION = 1
    # Phases holding new (nil-id) entities that the local DB may have meanwhile (see #db_stale?).
    NEW_ENTITY_PHASES = [2, 3, 5].freeze

    attr_reader :source_path, :progress, :actor, :user_id, :last_build_result
    # Relay legs still to enrich, when the Step 3 page already computed them (read by Verdicts::Phase3).
    attr_accessor :relay_enrichment_count

    # == Params
    # - file_path: the canonical working source path (already resolved by DataFix::SourceResolver);
    # - progress: an Import::Progress sink (Cable for interactive requests, Null/Ops for jobs);
    # - actor: :operator (interactive request) or :auto (job); user_id: the operator, for the edit markers.
    def self.for(file_path, progress: Import::Progress::Cable.new, actor: :operator, user_id: nil, source_resolver: nil)
      new(file_path, progress:, actor:, user_id:, source_resolver:)
    end

    # Current value of the 'data_fix.db_generation' ops setting (bumped by every successful local commit), or 0.
    def self.db_generation
      Ops.safely(0) { Ops.available? ? Ops::Setting.fetch(DB_GENERATION_KEY, 0).to_i : 0 }
    end

    # Bumps the 'data_fix.db_generation' setting; returns the new value (nil without the ops DB).
    def self.bump_db_generation!
      Ops.safely do
        next unless Ops.available?

        Ops::Setting.store!(DB_GENERATION_KEY, db_generation + 1)
      end
    end

    def initialize(source_path, progress: Import::Progress::Cable.new, actor: :operator, user_id: nil, source_resolver: nil)
      raise ArgumentError, "unknown actor #{actor.inspect}" unless ACTORS.include?(actor.to_sym)

      @source_path = source_path.to_s
      @progress = progress || Import::Progress::Null.new
      @actor = actor.to_sym
      @user_id = user_id
      @source_resolver = source_resolver
      reload!
    end

    # Forgets every memoized file read (call it after a write made outside the pipeline).
    def reload!
      @payloads = {}
      @verdicts = {}
      @source_sha256 = nil
      @result_free = nil
      @retry_needed = nil
      @db_generation = nil
      self
    end

    def source_resolver
      @source_resolver ||= DataFix::SourceResolver.new
    end

    # Season of the source (from its folder name; default season otherwise, as the review actions always did).
    def season
      @season ||= source_resolver.detect_season_from_pathname(source_path)
    end

    def season_id_from_path
      Ops::PipelineSource.season_id_for(source_path)
    end

    # SeasonBoard::DiskIndex base name (key of Ops::PipelineSource).
    def base
      Ops::PipelineSource.base_for(source_path)
    end

    def lt_format
      @lt_format ||= source_resolver.detect_layout_type(source_path)
    end

    def categories_cache
      @categories_cache ||= PdfResults::CategoriesCache.cached_for(season)
    end

    def phase_path(phase)
      source_resolver.default_phase_path_for(source_path, phase)
    end

    def phase_exists?(phase)
      File.exist?(phase_path(phase))
    end

    # Parsed phase file (memoized; {} when missing or unreadable).
    def phase_payload(phase)
      @payloads[phase.to_i] ||= read_payload(phase)
    end

    # Phase data: the 'data' section for phases 1-4, the flat payload (minus '_meta') for phase 5.
    def phase_data(phase)
      payload = phase_payload(phase)
      data = phase.to_i == 5 ? payload.except(PhaseFileManager::META_KEY) : payload[PhaseFileManager::DATA_KEY]
      data.is_a?(Hash) ? data : {}
    end

    def phase_meta(phase)
      meta = phase_payload(phase)[PhaseFileManager::META_KEY]
      meta.is_a?(Hash) ? meta : {}
    end

    def source_sha256
      @source_sha256 ||= File.exist?(source_path) ? Digest::SHA256.file(source_path).hexdigest : ''
    end

    # Parsed source file (shared with the resolver memo).
    def source_json
      source_resolver.parsed_source_json(source_path)
    rescue StandardError
      {}
    end

    # True for a result-free source (e.g. manifest-only) with nothing staged: only Phase 1 is needed to commit.
    def result_free?
      return @result_free unless @result_free.nil?

      @result_free = source_resolver.source_result_free?(source_path) && !DataFix::StagingPurger.known_source?(source_path)
    end

    # Phase 1 'header_date', or the date of the source file.
    def meeting_date
      phase_data(1)['header_date'].presence || source_resolver.source_meeting_date(source_path)
    end

    def db_generation
      @db_generation ||= self.class.db_generation
    end

    # == Builds

    # Builds one phase through its recipe, stamps '_meta.built' and runs the post-build step; returns the
    # refreshed Verdict. Raises EditedPhaseError for an edited phase unless +force+ (only the operator's rescan
    # passes it, never a job), MissingUpstreamError when an upstream phase file is missing (unless
    # +strict_upstream+ is false: the interactive review actions keep the solvers' tolerance), LeaseBusyError.
    # A build that raises stores a 'failed' verdict and re-raises.
    def build_phase!(phase, force: false, strict_upstream: true)
      phase = validate_phase!(phase)
      raise EditedPhaseError, "phase #{phase} of #{base} holds operator edits" if !force && phase_exists?(phase) && edited?(phase)

      check_upstream!(phase) if strict_upstream
      with_lease do
        @last_build_result = Recipes.build(self, phase) || {}
        forget!(phase)
        stamp_built!(phase, stats: @last_build_result[:stats])
        post_build!(phase)
      end
      verdict(phase, refresh: true)
    rescue EditedPhaseError, MissingUpstreamError, LeaseBusyError
      raise
    rescue StandardError => e
      store_failed_verdict(phase, e)
      raise
    end

    # Builds, in order, the missing phases and the stale unedited ones (up to +up_to+, or only +phases+).
    # Stops at the first stale EDITED phase, recording its verdict as 'stale' with reason 'edited' (never raises
    # for it), and when +deadline+ (a Time) has passed. Returns #summary.
    def prepare!(up_to: 5, phases: nil, deadline: nil)
      selected = PHASES.select { |phase| phase <= up_to.to_i && (phases.nil? || Array(phases).map(&:to_i).include?(phase)) }
      selected.each do |phase|
        break if deadline && Time.current > deadline

        if !phase_exists?(phase) || build_needed?(phase)
          build_phase!(phase)
        elsif stale?(phase).any?
          if edited?(phase)
            store_verdict(phase, edited_stale_verdict(phase))
            break
          end
          build_phase!(phase)
        end
      end
      summary
    end

    # True when the phase file must be (re)built before its review page can render: missing, or lacking its main
    # list (an older generator or a corrupted file; an empty list is valid for meeting-only sources).
    def build_needed?(phase)
      return true unless phase_exists?(phase)

      case phase.to_i
      when 2 then phase_data(2)['teams'].nil?
      when 3 then phase_data(3)['swimmers'].nil?
      else false
      end
    end

    # == Edit markers

    # True when the phase holds operator edits: an 'operator_edit' marker, a data digest different from the build
    # stamp (hand edits), or no build stamp at all (adopted pre-existing file).
    def edited?(phase)
      return false unless phase_exists?(phase)

      meta = phase_meta(phase)
      return true if meta['operator_edit'].present?

      built = meta['built']
      return true unless built.is_a?(Hash) && built['digest'].present?
      return true if built['by'] == 'adopted'

      Digests.data_digest(phase_payload(phase), phase) != built['digest']
    end

    # True for a pre-existing (adopted) phase file without operator edits made since: labelled
    # "edited (pre-existing)" by the stepper.
    def adopted?(phase)
      return false unless phase_exists?(phase)

      meta = phase_meta(phase)
      built = meta['built']
      meta['operator_edit'].blank? && (!built.is_a?(Hash) || built['by'] == 'adopted')
    end

    # Records an operator edit of +phase+ (action name): '_meta.operator_edit' (last MAX_EDIT_ACTIONS actions),
    # mirrored to Ops::PhaseVerdict#operator_edited_at; invalidates the Season board summary.
    def mark_edited!(phase, action:, user_id: @user_id) # rubocop:disable Naming/PredicateMethod
      phase = validate_phase!(phase)
      return false unless phase_exists?(phase)

      payload = read_payload(phase)
      meta = (payload[PhaseFileManager::META_KEY] = payload[PhaseFileManager::META_KEY].is_a?(Hash) ? payload[PhaseFileManager::META_KEY] : {})
      previous = meta['operator_edit'].is_a?(Hash) ? Array(meta['operator_edit']['actions']) : []
      edited_at = Time.current.utc
      meta['operator_edit'] = { 'at' => edited_at.iso8601, 'user_id' => user_id,
                                'actions' => (previous + [action.to_s]).last(MAX_EDIT_ACTIONS) }
      meta['built'] ||= adopted_stamp(phase, payload)
      write_payload!(phase, payload)
      mirror_operator_edit(phase, edited_at)
      invalidate_board!
      true
    end

    # Re-stamps a phase after a runner-made write (cascade, harmonizer, auto-verify): the new data digest (and the
    # given input keys, all by default) are recorded, so the write is neither an edit nor a staleness.
    # Keeps 'by' (an adopted file stays adopted) and the operator edit marker.
    # +generation+: also records the current data_fix.db_generation (after a matches refresh).
    def restamp!(phase, keys: nil, generation: false) # rubocop:disable Naming/PredicateMethod
      phase = validate_phase!(phase)
      return false unless phase_exists?(phase)

      forget!(phase)
      payload = read_payload(phase)
      meta = (payload[PhaseFileManager::META_KEY] = payload[PhaseFileManager::META_KEY].is_a?(Hash) ? payload[PhaseFileManager::META_KEY] : {})
      previous = meta['built'].is_a?(Hash) ? meta['built'].deep_dup : nil
      built = previous ? meta['built'] : adopted_stamp(phase, payload)
      fresh = Digests.projections(phase, self)
      fresh = fresh.slice(*Array(keys).map(&:to_s)) if keys
      built['digest'] = Digests.data_digest(payload, phase)
      built['inputs'] = (built['inputs'].is_a?(Hash) ? built['inputs'] : {}).merge(fresh)
      built['db_generation'] = db_generation if generation
      return false if built == previous # (nothing to record: no write)

      meta['built'] = built
      write_payload!(phase, payload)
      true
    end

    # The metadata a review GET keeps in step, written ONCE (only when something differs): the retry flag of the
    # source and, for a pre-existing file without a build stamp, the 'adopted' stamp. Returns the retry flag.
    # (A settled source is never written by a review GET.)
    def settle!(phase)
      retry_needed = retry_needed?
      return retry_needed unless phase_exists?(phase)

      payload = read_payload(phase)
      meta = (payload[PhaseFileManager::META_KEY] = payload[PhaseFileManager::META_KEY].is_a?(Hash) ? payload[PhaseFileManager::META_KEY] : {})
      changed = false
      if meta['retry_needed'] != retry_needed
        meta['retry_needed'] = retry_needed
        changed = true
      end
      unless meta['built'].is_a?(Hash)
        meta['built'] = adopted_stamp(phase, payload)
        changed = true
      end
      write_payload!(phase, payload) if changed
      retry_needed
    rescue StandardError => e
      Rails.logger.warn("[DataFix::Pipeline] settle failed for #{phase_path(phase)}: #{e.message}")
      retry_needed || false
    end

    # Retry flag of the source (crawler 'retry' sections), computed in memory.
    def retry_needed?
      @retry_needed = source_resolver.source_has_retry_section?(source_path) == true if @retry_needed.nil?
      @retry_needed == true
    end

    # == Staleness

    # [] when fresh, else one Hash per changed input: { 'upstream' => 2, 'what' => 'team ids', 'key' => 'p2' }
    # ('upstream' 0 = the source file; key 'db' = the local DB changed under new entities).
    # (named as in the phase 09 plan: returns the reasons, blank when fresh)
    def stale?(phase) # rubocop:disable Naming/PredicateMethod
      phase = validate_phase!(phase)
      return [] unless phase_exists?(phase)

      built = phase_meta(phase)['built']
      return [] unless built.is_a?(Hash) && built['inputs'].is_a?(Hash)

      reasons = Digests.projections(phase, self).filter_map do |key, value|
        stored = built['inputs'][key]
        next if stored.nil? || stored == value

        { 'upstream' => Digests::INPUTS[key][:upstream], 'what' => Digests::INPUTS[key][:what], 'key' => key }
      end
      reasons << { 'upstream' => 'db', 'what' => 'db_changed', 'key' => 'db' } if db_stale?(phase, built)
      reasons
    end

    # True when the phase holds new (nil-id) entities and the local DB was committed to since it was built.
    def db_stale?(phase, built = phase_meta(phase)['built'])
      return false unless NEW_ENTITY_PHASES.include?(phase.to_i) && built.is_a?(Hash) && built.key?('db_generation')
      return false if built['db_generation'].to_i >= db_generation

      new_entity_count(phase).positive?
    end

    # Number of nil-id teams (phase 2), swimmers (phase 3), or both (phase 5).
    def new_entity_count(phase)
      teams = -> { Array(phase_data(2)['teams']).count { |team| team['team_id'].blank? } }
      swimmers = -> { Array(phase_data(3)['swimmers']).count { |swimmer| swimmer['swimmer_id'].blank? } }
      case phase.to_i
      when 2 then teams.call
      when 3 then swimmers.call
      when 5 then teams.call + swimmers.call
      else 0
      end
    end

    # == Verdicts

    # DataFix::Verdict of the phase, from the ops cache when its fingerprint still matches (or freshly computed and
    # stored). Without the ops DB it is computed on the fly every time.
    def verdict(phase, refresh: false)
      phase = validate_phase!(phase)
      @verdicts.delete(phase) if refresh
      @verdicts[phase] ||= begin
        current = fingerprint(phase)
        row = refresh ? nil : stored_verdict_row(phase)
        if row && row.fingerprint == current
          Verdict.from_row(row)
        else
          compute_verdict(phase).tap { |verdict| store_verdict(phase, verdict, fingerprint: current) }
        end
      end
    end

    # Per-phase verdicts plus the overall stage (see Pipeline::Summary); persists the stage on Ops::PipelineSource.
    def summary(refresh: false)
      verdicts = PHASES.index_with { |phase| verdict(phase, refresh:) }
      Summary.build(pipeline: self, verdicts:).tap { |summary| store_stage(summary) }
    end

    # The Ops::PipelineSource row (nil without the ops DB).
    def source_row
      return @source_row if defined?(@source_row) && @source_row

      @source_row = Ops.safely { Ops::PipelineSource.for_path!(source_path, season_id: season_id_from_path) if Ops.available? }
    end

    # == Invalidation

    # The ONLY path that deletes phase files. Deletes the given phases (after '.orig' backups, see
    # SourceResolver#backup_phase_files) and, when phase 5 is among them, the source's data_import_* rows.
    # When any target phase is edited and +force+ is false, it deletes NOTHING: the source is marked blocked with
    # reason 'source_changed_under_edits' (the step header then offers "Rebuild (discard edits)").
    # Returns { phase_files:, deleted_temp_rows:, backups:, kept:, refused: }.
    def invalidate!(phases:, reason:, force: false)
      targets = Array(phases).map(&:to_i).select { |phase| PHASES.cover?(phase) }.uniq.sort
      existing = targets.select { |phase| phase_exists?(phase) }
      edited = existing.select { |phase| edited?(phase) }
      if edited.any? && !force
        block_for_source_change!(edited:, phases: targets, reason:)
        return { phase_files: [], deleted_temp_rows: 0, backups: [], kept: edited, refused: true }
      end

      backups = source_resolver.backup_phase_files(source_path, existing)
      paths = targets.map { |phase| phase_path(phase) }
      paths.each { |path| FileUtils.rm_f(path) }
      deleted_rows = targets.include?(5) ? DataFix::StagingPurger.delete_rows(source_path).values.sum : 0
      targets.each { |phase| forget!(phase) }
      clear_source_block!(targets)
      { phase_files: paths, deleted_temp_rows: deleted_rows, backups:, kept: [], refused: false }
    end

    # == Matching freshness

    # Re-resolves only the nil-id teams (phase 2) and swimmers (phase 3) against the local DB (operator-set ids,
    # confirmed rows and everything else are left alone), then re-stamps the files. Returns { teams:, swimmers: }
    # with the number of entries that found a match.
    def refresh_new_entities!
      with_lease do
        teams = refresh_new_teams!
        swimmers = refresh_new_swimmers!
        { teams:, swimmers: }
      end
    end

    # Runs the Phase 2 <=> Phase 3 harmonizer (team conflict hints into phase 2) and re-stamps phase 2 when it
    # wrote something. Returns the harmonizer stats.
    def harmonize!
      return Phase3Harmonizer.empty_phase3_consistency_stats unless phase_exists?(2) && phase_exists?(3)

      stats = Phase3Harmonizer.harmonize_phase2_phase3_team_links(source_path:, season_id: season&.id)
      if stats[:phase2_conflict_hints_added].to_i.positive?
        forget!(2)
        restamp!(2)
      end
      stats
    end

    private

    def validate_phase!(phase)
      value = Integer(phase)
      raise ArgumentError, "unknown phase #{phase.inspect}" unless PHASES.cover?(value)

      value
    end

    def read_payload(phase)
      path = phase_path(phase)
      return {} unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      payload.is_a?(Hash) ? payload : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def write_payload!(phase, payload)
      PhaseFileManager.new(phase_path(phase)).write_payload!(payload)
      forget!(phase)
    end

    def forget!(phase)
      @payloads.delete(phase.to_i)
      @verdicts.delete(phase.to_i)
      @verdicts.delete(5) # (the phase 5 verdict reads the upstream files too)
      @result_free = nil
    end

    def check_upstream!(phase)
      raise MissingUpstreamError, "source file missing: #{source_path}" unless File.exist?(source_path)

      missing = UPSTREAMS.fetch(phase).reject { |upstream| phase_exists?(upstream) }
      raise MissingUpstreamError, "phase #{phase} needs phase #{missing.join(', ')} first" if missing.any?
    end

    # Lease owner of this pipeline instance (re-entrant).
    def lease_owner
      @lease_owner ||= "#{actor}:#{Process.pid}:#{SecureRandom.hex(4)}"
    end

    def with_lease
      row = source_row
      return yield unless row

      raise LeaseBusyError, "#{base} is being built by #{row.lease_owner}" unless Ops.safely(true) { row.acquire_lease!(lease_owner) }

      begin
        yield
      ensure
        Ops.safely { row.release_lease!(lease_owner) }
      end
    end

    def built_by
      actor == :auto ? 'auto' : 'operator'
    end

    def stamp_built!(phase, stats: nil)
      payload = read_payload(phase)
      return unless payload.any?

      meta = (payload[PhaseFileManager::META_KEY] = payload[PhaseFileManager::META_KEY].is_a?(Hash) ? payload[PhaseFileManager::META_KEY] : {})
      meta.delete('operator_edit')
      meta['built'] = { 'by' => built_by, 'at' => Time.current.utc.iso8601, 'digest' => Digests.data_digest(payload, phase),
                        'inputs' => Digests.projections(phase, self), 'db_generation' => db_generation }
      meta['populate'] = populate_summary(stats) if phase == 5 && stats
      write_payload!(phase, payload)
    end

    # The 'built' stamp of an adopted (pre-existing) file: inputs taken now.
    def adopted_stamp(phase, payload)
      { 'by' => 'adopted', 'at' => Time.current.utc.iso8601, 'digest' => Digests.data_digest(payload, phase),
        'inputs' => Digests.projections(phase, self), 'db_generation' => db_generation }
    end

    # Phase 5 populate stats kept in '_meta.populate' (read by the phase 5 verdict).
    def populate_summary(stats)
      stats = stats.to_h
      {
        'errors' => Array(stats[:errors]).first(50).map(&:to_s), 'errors_count' => Array(stats[:errors]).size,
        'collisions' => Array(stats[:collisions]).first(50).map { |row| row.to_h.stringify_keys },
        'collisions_count' => Array(stats[:collisions]).size,
        'parity' => stats[:parity].to_h.deep_stringify_keys,
        'mir_created' => stats[:mir_created].to_i, 'relay_results_created' => stats[:relay_results_created].to_i,
        'auto_verify' => stats[:auto_verify].to_h.deep_stringify_keys
      }
    end

    # Phase 3 build: team conflict hints into phase 2. Phase 2 build: the same, when phase 3 exists (a rebuilt
    # phase 2 starts without hints).
    def post_build!(phase)
      harmonize! if [2, 3].include?(phase)
    end

    def refresh_new_teams!
      return 0 unless phase_exists?(2)

      payload = read_payload(2)
      data = payload[PhaseFileManager::DATA_KEY] || {}
      solver = Import::Solvers::TeamSolver.new(season:, progress: Import::Progress::Null.new)
      matched = 0
      Array(data['teams']).each do |team|
        next if team['team_id'].present? || team['confirmed'] == true

        fresh = solver.re_resolve_entry(team)
        next unless fresh

        matched += 1 if fresh['team_id'].present?
        team.merge!(fresh.slice('team_id', 'fuzzy_matches', 'match_percentage', 'similar_affiliated',
                                'editable_name', 'name', 'name_variations', 'city_id'))
        sync_team_affiliation!(data, team)
      end
      write_payload!(2, payload)
      restamp!(2, generation: true)
      matched
    end

    def sync_team_affiliation!(data, team)
      row = Array(data['team_affiliations']).find { |aff| aff['team_key'] == team['key'] }
      return unless row

      row['team_id'] = team['team_id']
      row['team_affiliation_id'] = (GogglesDb::TeamAffiliation.find_by(team_id: team['team_id'], season_id: season.id)&.id if team['team_id'])
    end

    def refresh_new_swimmers!
      return 0 unless phase_exists?(3)

      payload = read_payload(3)
      data = payload[PhaseFileManager::DATA_KEY] || {}
      solver = Import::Solvers::SwimmerSolver.new(season:, categories_cache:, progress: Import::Progress::Null.new)
      solver.prepare_context!(phase1_payload: phase_payload(1), phase2_payload: phase_payload(2))
      matched = 0
      Array(data['swimmers']).each do |swimmer|
        next if swimmer['swimmer_id'].present? || swimmer['confirmed'] == true

        fresh = solver.re_resolve_entry(swimmer)
        next unless fresh

        matched += 1 if fresh['swimmer_id'].present?
        swimmer.merge!(fresh.slice('swimmer_id', 'fuzzy_matches', 'match_percentage', 'complete_name', 'last_name',
                                   'first_name', 'gender_guessed', 'auto_assigned_from_secondary_match'))
        sync_swimmer_badges!(data, swimmer)
      end
      write_payload!(3, payload)
      restamp!(3, generation: true)
      matched
    end

    def sync_swimmer_badges!(data, swimmer)
      Array(data['badges']).each do |badge|
        next unless DataFix::SwimmerKey.swimmer_key_match?(badge['swimmer_key'], swimmer['key'], swimmer['key'])

        badge['swimmer_id'] = swimmer['swimmer_id']
        badge['badge_id'] = if swimmer['swimmer_id'] && badge['team_id'].to_i.positive?
                              GogglesDb::Badge.find_by(season_id: season.id, swimmer_id: swimmer['swimmer_id'],
                                                       team_id: badge['team_id'])&.id
                            end
      end
    end

    # == Verdict helpers

    # Cache key of the verdict: the files (and staging rows) it reads, the DB generation and the checker version.
    def fingerprint(phase)
      files = [source_path, *PHASES.to_a.first(phase).map { |n| phase_path(n) }]
      parts = files.map { |path| File.exist?(path) ? [File.mtime(path).to_r.to_s, File.size(path)] : nil }
      parts << staging_fingerprint if phase == 5
      parts << db_generation << VERDICT_VERSION << source_row&.stage_reason
      Digest::SHA256.hexdigest(parts.inspect)
    end

    def staging_fingerprint
      DataFix::StagingPurger::TABLES.values.map do |table|
        table.where(phase_file_path: source_path).pick(Arel.sql('COUNT(*)'), Arel.sql('MAX(updated_at)'))
      end
    rescue StandardError
      nil
    end

    def compute_verdict(phase)
      return skipped_verdict(phase) if phase > 1 && result_free? && !phase_exists?(phase)
      return Verdict.build(phase:, status: 'unbuilt') unless phase_exists?(phase)

      base_verdict = Verdicts.for(phase).new(self).call
      reasons = stale?(phase)
      issues = base_verdict.issues
      status = base_verdict.status
      if reasons.any?
        issues = [{ 'code' => 'stale', 'level' => 'stale', 'message' => reasons.pluck('what').uniq.join(', '),
                    'count' => reasons.size }] + issues
        status = 'stale'
      end
      built = phase_meta(phase)['built'] || {}
      base_verdict.with(status:, issues:, edited: edited?(phase), adopted: adopted?(phase), stale_reasons: reasons,
                        built_by: built['by'], built_at: built['at'])
    rescue StandardError => e
      Rails.logger.error("[DataFix::Pipeline] verdict #{phase} failed for #{source_path}: #{e.class}: #{e.message}")
      Verdict.build(phase:, status: 'failed', message: "#{e.class}: #{e.message}".truncate(500))
    end

    # Phases 2-5 of a result-free source: nothing to review (only Phase 1 is committed).
    def skipped_verdict(phase)
      Verdict.build(phase:, status: 'clean', counts: { 'skipped' => true })
    end

    def edited_stale_verdict(phase)
      current = verdict(phase)
      issue = { 'code' => 'edited_stale', 'level' => 'stale', 'message' => 'edited', 'count' => 1 }
      current.with(status: 'stale', issues: [issue] + current.issues.reject { |row| row['code'] == 'edited_stale' })
    end

    def stored_verdict_row(phase)
      row = source_row
      return nil unless row

      Ops.safely { Ops::PhaseVerdict.find_by(pipeline_source_id: row.id, phase:) }
    end

    def store_verdict(phase, verdict, fingerprint: nil)
      @verdicts[phase] = verdict
      row = source_row
      return verdict unless row

      Ops.safely do
        record = Ops::PhaseVerdict.find_or_initialize_by(pipeline_source_id: row.id, phase:)
        built = phase_meta(phase)['built'] || {}
        record.assign_attributes(
          status: verdict.status, issues_count: verdict.issues_count, issues: Ops::PhaseVerdict.capped_issues(verdict.issues),
          counts: verdict.counts_for_row, new_entities: Ops::PhaseVerdict.capped_new_entities(verdict.new_entities),
          built_by: built['by'], built_at: built['at'], built_digest: built['digest'], input_digests: built['inputs'] || {},
          operator_edited_at: phase_meta(phase).dig('operator_edit', 'at'), confirmed_count: verdict.counts['confirmed'],
          db_generation:, fingerprint: fingerprint || record.fingerprint, checked_at: Time.current
        )
        changed = record.new_record? || record.status_changed?
        record.save!
        invalidate_board! if changed
      end
      verdict
    end

    def store_failed_verdict(phase, error)
      phase = Integer(phase)
      return unless PHASES.cover?(phase)

      verdict = Verdict.build(phase:, status: 'failed', message: "#{error.class}: #{error.message}".truncate(500))
      store_verdict(phase, verdict, fingerprint: Ops.safely { fingerprint(phase) })
    rescue StandardError
      nil
    end

    def mirror_operator_edit(phase, edited_at)
      row = source_row
      return unless row

      Ops.safely do
        record = Ops::PhaseVerdict.find_or_initialize_by(pipeline_source_id: row.id, phase:)
        record.status ||= 'review'
        record.operator_edited_at = edited_at
        record.save!
      end
    end

    def store_stage(summary)
      row = source_row
      return unless row

      Ops.safely do
        attributes = { stage: summary.stage, review_phase: summary.review_phase, review_count: summary.review_count,
                       new_teams_count: summary.new_teams.size, new_swimmers_count: summary.new_swimmers.size,
                       db_generation:, source_kind: summary.source_kind, source_sha256: source_sha256.presence,
                       fin_event_id: source_fin_event_id }
        attributes[:stage] = 'blocked' if row.source_changed_under_edits?
        row.assign_attributes(attributes)
        changed = row.stage_changed?
        row.save! if row.changed?
        invalidate_board! if changed
      end
    end

    def source_fin_event_id
      FINEventId.parse_any(source_json['meetingURL'], source_json['manifestURL'])
    rescue StandardError
      nil
    end

    def block_for_source_change!(edited:, phases:, reason:)
      Rails.logger.warn("[DataFix::Pipeline] #{reason}: kept the edited phases #{edited.inspect} of #{source_path}")
      row = source_row
      return unless row

      Ops.safely do
        row.update!(stage: 'blocked', stage_reason: Ops::PipelineSource::SOURCE_CHANGED_UNDER_EDITS,
                    stage_details: { 'phases' => phases, 'edited' => edited, 'reason' => reason.to_s, 'at' => Time.current.utc.iso8601 })
        invalidate_board!
      end
    end

    def clear_source_block!(phases)
      row = source_row
      return unless row

      Ops.safely do
        Ops::PhaseVerdict.where(pipeline_source_id: row.id, phase: phases).delete_all
        if row.source_changed_under_edits?
          row.update!(stage: 'new', stage_reason: nil, stage_details: {})
          invalidate_board!
        end
      end
    end

    def invalidate_board!
      season_id = season_id_from_path
      SeasonBoard::Snapshot.invalidate!(season_id) if season_id.positive?
    rescue StandardError
      nil
    end
  end
end
