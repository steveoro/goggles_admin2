# frozen_string_literal: true

module DataFix
  # IssueDetector: server-side issue detection for phase-5 review — checks that
  # every staging row's links (swimmer/team/badge/affiliation) are resolvable
  # from the phase files, plus program-level aggregation used by the filters
  # and the per-card warning badges.
  module IssueDetector
    module_function

    # Check if a swimmer (from phase3) has missing critical data
    # Returns hash with { missing_gender: bool, missing_year: bool, not_found: bool }
    # Uses partial key matching to handle different key formats
    #
    # @param swimmer_key [String] the swimmer key to check
    # @param swimmers_by_key [Hash] swimmers indexed by key (from phase3)
    # @return [Hash] { missing_gender: bool, missing_year: bool, not_found: bool }
    def swimmer_has_missing_data?(swimmer_key, swimmers_by_key: {}) # rubocop:disable Naming/PredicateMethod
      return { missing_gender: false, missing_year: false, not_found: true } unless swimmers_by_key.present? && swimmer_key

      # First try exact match
      swimmer = swimmers_by_key[swimmer_key]

      # If not found, try partial key matching (ignoring gender prefix)
      unless swimmer
        partial_key = SwimmerKey.normalize_swimmer_key_for_lookup(swimmer_key)
        if partial_key
          swimmer = swimmers_by_key.values.find do |s|
            SwimmerKey.normalize_swimmer_key_for_lookup(s['key']) == partial_key
          end
        end
      end

      # If swimmer not found in Phase 3, this is an issue
      return { missing_gender: true, missing_year: false, not_found: true } unless swimmer

      {
        missing_gender: swimmer['gender_type_code'].blank?,
        missing_year: swimmer['year_of_birth'].blank? || swimmer['year_of_birth'].to_i.zero?,
        not_found: false
      }
    end

    def team_link_resolvable?(team_id:, team_key:)
      team_id.to_i.positive? || team_key.present?
    end

    def swimmer_link_resolvable?(swimmer_id:, swimmer_key:, swimmers_by_key:)
      return true if swimmer_id.to_i.positive?
      return false if swimmer_key.blank?

      swimmer_issues = swimmer_has_missing_data?(swimmer_key, swimmers_by_key: swimmers_by_key)
      !swimmer_issues[:missing_gender] && !swimmer_issues[:missing_year] && !swimmer_issues[:not_found]
    end

    def individual_badge_link_resolvable?(mir, swimmer_resolvable:, team_resolvable:)
      return true if mir.badge_id.to_i.positive?

      swimmer_resolvable && team_resolvable
    end

    def relay_swimmer_badge_link_resolvable?(relay_swimmer:, parent_team_id:, team_key:, swimmer_resolvable:)
      return true if relay_swimmer.badge_id.to_i.positive?

      swimmer_resolvable && team_link_resolvable?(team_id: parent_team_id, team_key: team_key)
    end

    def relay_result_has_issues?(relay_result, relay_swimmers_by_key:, swimmers_by_id:, swimmers_by_key: {}, # rubocop:disable Naming/PredicateMethod
                                 badges_by_id: {}, affiliations_by_id: {}, season_id: nil)
      relay_swimmers = relay_swimmers_by_key[relay_result.import_key] || []
      issues = {}

      # meeting_program_id may be nil here for NEW programs to be created in phase 6;
      # this is not an issue by itself as long as program key includes gender and all
      # other required links/coherence checks pass.

      if SwimmerKey.program_key_missing_gender?(relay_result.meeting_program_key)
        issues[:program_gender] = {
          missing_program_gender: true
        }
      end

      team_resolvable = team_link_resolvable?(team_id: relay_result.team_id, team_key: relay_result.team_key)

      unless team_resolvable
        issues[:required_fks] = {
          missing_team_id: relay_result.team_id.to_i <= 0,
          missing_team_key: relay_result.team_key.blank?
        }
      end

      if relay_result.team_affiliation_id.to_i.positive?
        affiliation = affiliations_by_id[relay_result.team_affiliation_id] ||
                      GogglesDb::TeamAffiliation.find_by(id: relay_result.team_affiliation_id)
        if affiliation.nil? || affiliation.team_id != relay_result.team_id || (season_id.to_i.positive? && affiliation.season_id != season_id.to_i)
          issues[:team_affiliation_mismatch] = {
            team_id: relay_result.team_id,
            team_affiliation_id: relay_result.team_affiliation_id,
            season_id: season_id
          }
        end
      end

      relay_swimmers.each do |rs|
        swimmer_resolvable = swimmer_link_resolvable?(
          swimmer_id: rs.swimmer_id,
          swimmer_key: rs.swimmer_key,
          swimmers_by_key: swimmers_by_key
        )
        badge_resolvable = relay_swimmer_badge_link_resolvable?(
          relay_swimmer: rs,
          parent_team_id: relay_result.team_id,
          team_key: relay_result.team_key,
          swimmer_resolvable: swimmer_resolvable
        )

        unless swimmer_resolvable && badge_resolvable
          issues[rs.relay_order] = {
            swimmer_key: rs.swimmer_key,
            missing_swimmer_binding: !swimmer_resolvable,
            missing_badge_binding: !badge_resolvable
          }
          next
        end

        if rs.badge_id.to_i.positive?
          badge = badges_by_id[rs.badge_id] || GogglesDb::Badge.find_by(id: rs.badge_id)
          if badge.nil? || badge.swimmer_id != rs.swimmer_id || (relay_result.team_id.to_i.positive? && badge.team_id != relay_result.team_id)
            issues[rs.relay_order] = {
              swimmer_key: rs.swimmer_key,
              badge_mismatch: true
            }
            next
          end
        end

        swimmer = swimmers_by_id[rs.swimmer_id]
        next unless swimmer

        missing_gender = swimmer.gender_type_id.blank?
        missing_year = swimmer.year_of_birth.blank? || swimmer.year_of_birth.to_i.zero?

        next unless missing_gender || missing_year

        issues[rs.relay_order] = {
          swimmer_key: "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}",
          missing_gender: missing_gender,
          missing_year: missing_year
        }
      end

      {
        has_issues: issues.any?,
        issue_count: issues.size,
        issues: issues
      }
    end

    # Check if an individual result has issues.
    # meeting_program_id may be nil for NEW programs, but all other links must be resolved.
    # Issues include:
    #   - missing program gender in meeting_program_key
    #   - missing swimmer/team/badge IDs
    #   - badge/team/swimmer incoherence
    #   - missing team affiliation for current season (when season is known)
    #   - matched swimmer missing gender or year of birth
    #
    # @param mir [DataImportMeetingIndividualResult] the individual result to check
    # @param swimmers_by_id [Hash] swimmers indexed by ID
    # @param swimmers_by_key [Hash] swimmers indexed by key (from phase3)
    # @return [Boolean] true if result has issues
    def result_has_issues?(mir, swimmers_by_id:, swimmers_by_key: {}, badges_by_id: {},
                           season_id: nil, team_ids_with_affiliation: nil)
      return true if SwimmerKey.program_key_missing_gender?(mir.meeting_program_key)

      # meeting_program_id may be nil for NEW programs; remaining links are valid
      # when they are either already bound by ID or solvable via keys.
      swimmer_resolvable = swimmer_link_resolvable?(
        swimmer_id: mir.swimmer_id,
        swimmer_key: mir.swimmer_key,
        swimmers_by_key: swimmers_by_key
      )
      team_resolvable = team_link_resolvable?(team_id: mir.team_id, team_key: mir.team_key)
      badge_resolvable = individual_badge_link_resolvable?(mir, swimmer_resolvable: swimmer_resolvable, team_resolvable: team_resolvable)
      return true unless swimmer_resolvable && team_resolvable && badge_resolvable

      if mir.badge_id.to_i.positive?
        badge = badges_by_id[mir.badge_id]
        return true unless badge && badge.swimmer_id == mir.swimmer_id && badge.team_id == mir.team_id
      end

      if season_id.to_i.positive? && mir.team_id.to_i.positive?
        affiliation_exists =
          if team_ids_with_affiliation
            team_ids_with_affiliation.include?(mir.team_id)
          else
            GogglesDb::TeamAffiliation.exists?(team_id: mir.team_id, season_id: season_id.to_i)
          end
        # team_affiliation_id is not persisted on data_import MIR rows: if missing in DB,
        # this is still considered solvable (new team affiliation) when team binding is solvable.
        return true unless affiliation_exists || team_resolvable
      end

      # Matched swimmer - check if missing gender or year
      swimmer = swimmers_by_id[mir.swimmer_id]
      return false unless swimmer # If swimmer not found in lookup, skip (data loading issue)

      swimmer.gender_type_id.nil? || swimmer.year_of_birth.nil?
    end

    # Load minimal data needed for filtering programs
    # Loads only what's necessary to detect issues without loading full display data
    #
    # @param source_path [String] source file path
    # @return [Hash] { relay_swimmers_by_parent_key:, swimmers_by_id:, swimmers_by_key:, badges_by_id:, affiliations_by_id:, season_id: }
    def load_filter_data(source_path, staging)
      # Load phase3 data for unmatched swimmer lookup
      # Index by both full key AND partial key for flexible matching
      phase3_path = SourceResolver.new.default_phase_path_for(source_path, 3)
      swimmers_by_key = {}
      if File.exist?(phase3_path)
        swimmers = PhaseFileManager.new(phase3_path).data['swimmers'] || []
        swimmers.each do |s|
          # Index by full key
          swimmers_by_key[s['key']] = s
          # Also index by partial key (gender stripped, team preserved) for flexible lookup
          partial_key = SwimmerKey.normalize_swimmer_key_for_lookup(s['key'])
          next unless partial_key

          swimmers_by_key[partial_key] = s
          # And without leading pipe
          swimmers_by_key[partial_key.sub(/^\|/, '')] = s
        end
      end

      # Relay swimmers grouped by parent key (from the shared staging rows)
      relay_swimmers_by_parent_key = staging[:relay_swimmers].group_by(&:parent_import_key)

      # Load swimmers by ID for BOTH individual AND relay results
      individual_swimmer_ids = staging[:mirs].filter_map(&:swimmer_id).uniq
      relay_swimmer_ids = staging[:relay_swimmers].filter_map(&:swimmer_id).uniq
      all_swimmer_ids = (individual_swimmer_ids + relay_swimmer_ids).uniq
      swimmers_by_id = GogglesDb::Swimmer.where(id: all_swimmer_ids).index_by(&:id)

      badge_ids = staging[:mirs].filter_map(&:badge_id) +
                  staging[:relay_swimmers].filter_map(&:badge_id)
      badges_by_id = GogglesDb::Badge.where(id: badge_ids.uniq).index_by(&:id)

      affiliation_ids = staging[:mrrs].filter_map(&:team_affiliation_id)
      affiliations_by_id = GogglesDb::TeamAffiliation.where(id: affiliation_ids.uniq).index_by(&:id)

      season_id = (if File.exist?(SourceResolver.new.default_phase_path_for(
                                    source_path, 1
                                  ))
                     PhaseFileManager.new(SourceResolver.new.default_phase_path_for(source_path,
                                                                                    1)).data['season_id']
                   end)

      # Team IDs that already have a TeamAffiliation in the current season,
      # preloaded once so result_has_issues? doesn't run an EXISTS? per result.
      mir_team_ids = staging[:mirs].filter_map(&:team_id).uniq
      team_ids_with_affiliation =
        if season_id.to_i.positive? && mir_team_ids.any?
          GogglesDb::TeamAffiliation
            .where(team_id: mir_team_ids, season_id: season_id.to_i)
            .distinct
            .pluck(:team_id)
            .to_set
        else
          Set.new
        end

      {
        relay_swimmers_by_parent_key: relay_swimmers_by_parent_key,
        swimmers_by_id: swimmers_by_id,
        swimmers_by_key: swimmers_by_key,
        badges_by_id: badges_by_id,
        affiliations_by_id: affiliations_by_id,
        team_ids_with_affiliation: team_ids_with_affiliation,
        season_id: season_id
      }
    end

    # Detect programs with issues (missing swimmer data, unmatched swimmers, etc.)
    # Run server-side BEFORE pagination to provide accurate issue counts
    #
    # @param programs [Array<Hash>] all programs from phase5 JSON
    # @param filter_data [Hash] data needed for filtering
    # @param staging [Hash] buckets from load_staging_rows
    # @return [Array<Hash>] programs with at least one result with issues
    def detect_programs_with_issues(programs, filter_data, staging)
      relay_swimmers_by_parent_key = filter_data[:relay_swimmers_by_parent_key]
      swimmers_by_id = filter_data[:swimmers_by_id]
      swimmers_by_key = filter_data[:swimmers_by_key]
      badges_by_id = filter_data[:badges_by_id] || {}
      affiliations_by_id = filter_data[:affiliations_by_id] || {}
      team_ids_with_affiliation = filter_data[:team_ids_with_affiliation]
      season_id = filter_data[:season_id]

      programs.select do |prog|
        next true if prog['gender_code'].blank?

        program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"

        if prog['relay']
          # Check if any relay results in this program have issues
          relay_results = staging[:mrrs_by_program][program_key] || []

          relay_results.any? do |mrr|
            issue_info = relay_result_has_issues?(
              mrr,
              relay_swimmers_by_key: relay_swimmers_by_parent_key,
              swimmers_by_id: swimmers_by_id,
              swimmers_by_key: swimmers_by_key,
              badges_by_id: badges_by_id,
              affiliations_by_id: affiliations_by_id,
              season_id: season_id
            )
            issue_info[:has_issues]
          end
        else
          # Check if any individual results in this program have issues
          individual_results = staging[:mirs_by_program][program_key] || []

          individual_results.any? do |mir|
            result_has_issues?(
              mir,
              swimmers_by_id: swimmers_by_id,
              swimmers_by_key: swimmers_by_key,
              badges_by_id: badges_by_id,
              season_id: season_id,
              team_ids_with_affiliation: team_ids_with_affiliation
            )
          end
        end
      end
    end
  end
end
