# frozen_string_literal: true

module Import
  #
  # = Import::CommitPreflight
  #
  # Read-only checks run before a Phase 6 commit (modelled on Import::StructureValidator): it writes nothing and
  # returns +errors+ / +warnings+ (Hashes with :code, :message, :count, :phase, :details) for what today only
  # Import::Committers::Main finds while committing:
  #
  # - every Phase 5 program must find its event ("<session_order>-<event_key>") among the Phase 4 events
  #   committable under a Phase 1 session (Main skips the program otherwise);
  # - category and gender of every program resolvable (relays may fall back to their swimmers: warning only);
  # - the overwrite snapshot still valid (DataFix::IndividualResultOverwriteReconciler.commit_plan_for);
  # - the FIN event id not linked to a calendar of ANOTHER meeting (Import::Committers::Calendar);
  # - EXACT-NAME check: every nil-id team (editable name or name) and nil-id swimmer (complete name + year +
  #   gender) that would be created is looked up in the local DB: a hit is an error ("would duplicate team 123;
  #   refresh matches"), downgraded to a warning by +create_anyway+ (the operator's explicit override);
  # - a team score whose team key has no Phase 2 team: warning.
  #
  # Runs in the Phase 5 verdict, on the commit summary page and again at commit job start.
  #
  class CommitPreflight # rubocop:disable Metrics/ClassLength
    Result = Data.define(:errors, :warnings) do
      def ok? = errors.empty?

      def to_h
        { 'errors' => errors.map { |row| row.transform_keys(&:to_s) }, 'warnings' => warnings.map { |row| row.transform_keys(&:to_s) } }
      end
    end

    GENDER_CODES = %w[M F X].freeze

    attr_reader :pipeline, :create_anyway

    # == Params
    # - pipeline: the DataFix::Pipeline of the source;
    # - create_anyway: true when the operator confirmed the creation of entities whose exact names already exist.
    def initialize(pipeline:, create_anyway: false)
      @pipeline = pipeline
      @create_anyway = create_anyway
      @errors = []
      @warnings = []
    end

    def call
      check_fin_link
      check_exact_names
      unless pipeline.result_free?
        check_programs
        check_overwrite
        check_team_scores
      end
      Result.new(errors: @errors, warnings: @warnings)
    rescue StandardError => e
      Rails.logger.error("[Import::CommitPreflight] #{pipeline.source_path}: #{e.class}: #{e.message}")
      Result.new(errors: @errors + [entry(:preflight_failed, "#{e.class}: #{e.message}".truncate(300), phase: 5)], warnings: @warnings)
    end

    # Nil-id teams and swimmers whose exact name exists in the local DB ({ teams: [...], swimmers: [...] }).
    def exact_name_hits
      @exact_name_hits ||= { teams: team_name_hits, swimmers: swimmer_name_hits }
    end

    private

    def entry(code, message, count: 1, phase: nil, details: nil)
      { code: code.to_s, message:, count:, phase:, details: Array(details).first(20).presence }.compact
    end

    def error!(...) = @errors << entry(...)
    def warning!(...) = @warnings << entry(...)

    def phase1 = pipeline.phase_data(1)
    def phase2 = pipeline.phase_data(2)
    def phase3 = pipeline.phase_data(3)
    def phase4 = pipeline.phase_data(4)
    def phase5 = pipeline.phase_data(5)

    def check_fin_link # rubocop:disable Metrics/AbcSize
      fin_event_id = FINEventId.parse_any(phase1['meetingURL'], phase1['results_link'], phase1['manifestURL'], phase1['manifest_link'])
      return if fin_event_id.blank? || phase1['season_id'].blank?

      row = GogglesDb::Calendar.where(season_id: phase1['season_id'], results_code: fin_event_id).first
      return if row.nil? || row.meeting_id.nil? || row.meeting_id == phase1['id'].to_i

      error!(:fin_link_conflict, "FIN event #{fin_event_id} is already linked to meeting #{row.meeting_id} (calendar #{row.id})", phase: 1)
    end

    def check_exact_names # rubocop:disable Metrics/AbcSize
      hits = exact_name_hits
      report = create_anyway ? method(:warning!) : method(:error!)
      if hits[:teams].any?
        report.call(:existing_team_name, hits[:teams].map { |hit| "#{hit['name']} (team #{hit['id']})" }.first(5).join(', '),
                    count: hits[:teams].size, phase: 2, details: hits[:teams])
      end
      return if hits[:swimmers].empty?

      report.call(:existing_swimmer_name, hits[:swimmers].map { |hit| "#{hit['name']} (swimmer #{hit['id']})" }.first(5).join(', '),
                  count: hits[:swimmers].size, phase: 3, details: hits[:swimmers])
    end

    # (one query for all the new teams; MySQL compares the names case-insensitively)
    def team_name_hits # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      candidates = Array(phase2['teams']).filter_map do |team|
        next if team['team_id'].present?

        names = [team['editable_name'], team['name']].compact_blank.map { |name| name.to_s.strip }.uniq
        [team, names] if names.any?
      end
      return [] if candidates.empty?

      all_names = candidates.flat_map(&:last).uniq
      rows = GogglesDb::Team.where(editable_name: all_names).or(GogglesDb::Team.where(name: all_names)).order(:id)
                            .pluck(:id, :editable_name, :name)
      candidates.filter_map do |team, names|
        wanted = names.to_set(&:downcase)
        hit = rows.find { |_id, editable, name| wanted.include?(editable.to_s.downcase) || wanted.include?(name.to_s.downcase) }
        { 'key' => team['key'], 'name' => names.first, 'id' => hit.first } if hit
      end
    end

    # (one query for all the new swimmers: same complete name, year of birth and gender)
    def swimmer_name_hits # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      candidates = Array(phase3['swimmers']).select do |swimmer|
        swimmer['swimmer_id'].blank? && swimmer['complete_name'].present? && swimmer['year_of_birth'].to_i.positive?
      end
      return [] if candidates.empty?

      gender_ids = GogglesDb::GenderType.all.to_h { |gender| [gender.code.to_s.upcase, gender.id] }
      rows = GogglesDb::Swimmer.where(complete_name: candidates.map { |swimmer| swimmer['complete_name'].to_s.strip }.uniq)
                               .order(:id).pluck(:id, :complete_name, :year_of_birth, :gender_type_id)
      candidates.filter_map do |swimmer|
        gender_id = gender_ids[swimmer['gender_type_code'].to_s.upcase]
        hit = rows.find do |_id, name, year, gender|
          name.to_s.casecmp?(swimmer['complete_name'].to_s.strip) && year.to_i == swimmer['year_of_birth'].to_i &&
            (gender_id.nil? || gender == gender_id)
        end
        { 'key' => swimmer['key'], 'name' => swimmer['complete_name'], 'id' => hit.first } if hit
      end
    end

    # Phase 4 lookup keys committable by Main (events under a Phase 1 session).
    def committable_event_keys
      session_orders = Array(phase1['meeting_session']).each_with_index.to_set { |session, index| (session['session_order'] || (index + 1)).to_i }
      Array(phase4['sessions']).each_with_object(Set.new) do |session, keys|
        next unless session_orders.include?(session['session_order'].to_i)

        Array(session['events']).each do |event|
          keys << "#{event['session_order'] || session['session_order']}-#{event['key']}"
        end
      end
    end

    def check_programs
      keys = committable_event_keys
      programs = Array(phase5['programs'])
      missing = programs.reject { |program| keys.include?("#{program['session_order']}-#{program['event_key']}") }
      if missing.any?
        error!(:program_event_missing, "#{missing.size} program(s) without a Phase 4 event", count: missing.size, phase: 4,
                                                                                             details: missing.map do |program|
                                                                                               "#{program['session_order']}-#{program['event_key']}"
                                                                                             end.uniq)
      end

      check_program_categories(programs)
    end

    def check_program_categories(programs) # rubocop:disable Metrics/AbcSize
      cache = pipeline.categories_cache
      unresolved = programs.reject { |program| category_resolvable?(cache, program['category_code'], relay: program['relay'] == true) }
      relays, individuals = unresolved.partition { |program| program['relay'] == true }
      if individuals.any?
        error!(:category_unresolved, individuals.pluck('category_code').uniq.join(', '),
               count: individuals.size, phase: 5)
      end
      warning!(:relay_category_unresolved, relays.pluck('category_code').uniq.join(', '), count: relays.size, phase: 5) if relays.any?

      bad_gender = programs.reject { |program| GENDER_CODES.include?(program['gender_code'].to_s.upcase.first) }
      error!(:gender_unresolved, nil, count: bad_gender.size, phase: 5) if bad_gender.any?
    end

    def category_resolvable?(cache, code, relay:)
      return false if code.blank?
      return true if cache&.[](code)

      scope = GogglesDb::CategoryType.where(code:, season_id: pipeline.season&.id)
      scope = scope.where(relay: true) if relay
      scope.exists? || (relay && code.to_s[/\d+/].to_i.positive?)
    end

    def check_overwrite
      overwrite = pipeline.phase_meta(5)['individual_result_overwrite']
      return unless overwrite.is_a?(Hash) && overwrite['enabled'] == true

      plan = DataFix::IndividualResultOverwriteReconciler.commit_plan_for(
        meeting_id: phase1['id'] || phase1['meeting_id'],
        import_rows: GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: pipeline.source_path).to_a,
        snapshot: overwrite['snapshot']
      )
      timing_changes = Array(plan['reassign_targets'].values).count { |target| target['timing_exact'] == false }
      warning!(:overwrite_timing_corrections, 'category corrections will replace stale laps', count: timing_changes, phase: 5) if timing_changes.positive?
    rescue ArgumentError => e
      error!(:overwrite_snapshot_invalid, e.message, phase: 5)
    end

    def check_team_scores
      team_keys = Array(phase2['teams']).to_set { |team| team['key'] }
      orphans = Array(phase2['team_scores']).reject { |score| team_keys.include?(score['team_key']) }
      warning!(:team_score_without_team, orphans.pluck('team_key').first(5).join(', '), count: orphans.size, phase: 2) if orphans.any?
    end
  end
end
