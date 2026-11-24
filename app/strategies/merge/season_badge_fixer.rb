# frozen_string_literal: true

module Merge
  #
  # = Merge::SeasonBadgeFixer
  #
  # Plans the badge fixes of a whole season, ONE STEP per call (the steps of the former 'merge:season_fix' task):
  #   0. 'possible' badge merges (Merge::BadgeSeasonChecker#possible_badge_merges): only with +include_possible+ AND a
  #      team filter;
  #   1. 'sure' badge merges (#sure_badge_merges: dest = first badge, source = second);
  #   2. 'relay-only' badges (#relay_only_badges: category auto-fix, no destination);
  #   3. the remaining relay badges (#relay_badges, same).
  # Each candidate becomes a Merge::Badge (force: true when the destination is on +dest_team_id+, else autofix: true,
  # as 'merge:season_fix' did) and its own single-transaction block in #sql_log (one script per step, each badge in
  # its own transaction: see the transaction note of Merge::Badge#handle_mprogram_insert_or_select).
  #
  # Never writes: the step is planned on the current data. Since the badges are not applied one by one any more
  # (the former task ran each badge script right away), a candidate is DEFERRED to the next run when it touches a
  # badge already planned in this step, or when it would insert a meeting program that an earlier badge of the step
  # inserts too (Merge::Badge checks the programs on the current data, so both would insert it). The next run (after
  # the apply and the health re-run) plans what is left, the next step included.
  #
  # Differences from 'merge:season_fix' (decided in phase 13): no team filter means EVERY candidate (the task skipped
  # them all: 'src_team.to_i' gave 0); step 3 ends like the others; a candidate whose Merge::Badge raises is reported
  # as failed instead of stopping the run; the Outbox allocates the script numbers.
  #
  # == Usage
  #   fixer = Merge::SeasonBadgeFixer.new(season:, src_team_id: 123).prepare
  #   fixer.step        # => :sure (nil when nothing is left)
  #   fixer.sql_log     # => the step script lines
  #   fixer.counts      # => { possible: nil, sure: 3, relay_only: 0, relay: 1 } (candidates after the team filter)
  #
  class SeasonBadgeFixer # rubocop:disable Metrics/ClassLength
    STEPS = %i[possible sure relay_only relay].freeze
    STEP_NUMBERS = { possible: 0, sure: 1, relay_only: 2, relay: 3 }.freeze
    STEP_NAMES = { possible: "'POSSIBLE badge merges'", sure: "'sure badge merges'", relay_only: "'relay-only' badges",
                   relay: 'remaining relay badges' }.freeze
    # The meeting program insert of Merge::Badge#handle_mprogram_insert_or_select (event, category, gender captured).
    PROGRAM_INSERT_REGEXP = Regexp.new(
      "#{Regexp.escape('INSERT INTO meeting_programs (updated_at, meeting_event_id, category_type_id, gender_type_id, autofilled) VALUES (NOW(), ')}" \
      '(\\d+), (\\d+), (\\d+), 1\\);'
    )

    # One candidate: source / dest (nil for a category fix) badges, +status+ (:planned, :deferred, :failed), the
    # merge mode (:force or :autofix), the Merge::Badge lines (planned only) and the reason (deferred / failed).
    Outcome = Data.define(:source_id, :dest_id, :team_id, :status, :mode, :sql_lines, :message) do
      def planned? = status == :planned
      def deferred? = status == :deferred
      def failed? = status == :failed

      def to_h
        { 'source_id' => source_id, 'dest_id' => dest_id, 'team_id' => team_id, 'status' => status.to_s,
          'mode' => mode.to_s, 'message' => message }.compact
      end
    end

    attr_reader :season, :include_possible, :src_team_id, :dest_team_id, :checker, :step, :outcomes, :counts,
                :skipped_steps

    # == Params
    # - season: GogglesDb::Season (required);
    # - include_possible: also step 0 (requires +src_team_id+);
    # - src_team_id: only the candidates whose source badge is on this team (nil: every candidate);
    # - dest_team_id: (requires +src_team_id+) a candidate whose destination is on this team is merged with force;
    # - progress: optional callable (done, total, label), called before each candidate (it may raise to stop).
    def initialize(season:, include_possible: false, src_team_id: nil, dest_team_id: nil, progress: nil) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      raise(ArgumentError, 'season must be a Season!') unless season.is_a?(GogglesDb::Season)
      raise(ArgumentError, 'dest_team_id requires a src_team_id') if dest_team_id.present? && src_team_id.blank?
      raise(ArgumentError, "the 'possible' merges require a src_team_id") if include_possible && src_team_id.blank?

      @season = season
      @include_possible = include_possible ? true : false
      @src_team_id = src_team_id.presence&.to_i
      @dest_team_id = dest_team_id.presence&.to_i
      @progress = progress
      @outcomes = []
      @counts = {}
      @skipped_steps = {}
    end

    # Runs the checker and plans the first step having at least one plannable candidate. Returns self.
    def prepare
      @checker = Merge::BadgeSeasonChecker.new(season:)
      @checker.run
      @counts = STEPS.index_with { |step| active_step?(step) ? candidates_for(step).size : nil }
      STEPS.each do |step|
        next unless active_step?(step)

        candidates = candidates_for(step)
        next if candidates.empty?

        outcomes = plan_step(step, candidates)
        if outcomes.any?(&:planned?)
          @step = step
          @outcomes = outcomes
          break
        end
        @skipped_steps[step] = outcomes # (every candidate failed: reported, the next step is tried)
      end
      self
    end

    def step_number = step && STEP_NUMBERS[step]
    def step_name = step && STEP_NAMES[step]

    def planned = outcomes.select(&:planned?)
    def deferred = outcomes.select(&:deferred?)
    def failed = outcomes.select(&:failed?) + skipped_steps.values.flatten

    # The script of the step: a header, then each planned badge in its own transaction.
    def sql_log
      return [] if step.nil?

      header = ["-- Season badge fix: season #{season.id}, step #{step_number} #{step_name}: #{planned.size} badge(s)" \
                "#{", #{deferred.size} deferred to the next run" if deferred.any?}",
                '-- (each badge in its own transaction: a badge fix may insert a meeting program used by the next one)']
      header + planned.flat_map { |outcome| ['', *outcome.sql_lines] }
    end

    # True when another run may find something to do (deferred candidates or later steps with candidates).
    def more_to_do?
      return false if step.nil?

      deferred.any? || STEPS.drop(STEPS.index(step) + 1).any? { |later| counts[later].to_i.positive? } ||
        (step == :sure && planned.any?) # (the checker pairs only the first couple per swimmer)
    end

    # The candidates of a step after the team filter: Array of [source badge, dest badge or nil].
    def candidates_for(step)
      @candidates ||= {}
      @candidates[step] ||= raw_candidates(step).filter_map do |entry|
        source, dest = entry.respond_to?(:second) ? [entry.second, entry.first] : [entry, nil]
        next if source.nil?
        next if src_team_id && source.team_id != src_team_id

        [source, dest]
      end
    end

    private

    def active_step?(step) = step != :possible || include_possible

    def raw_candidates(step)
      case step
      when :possible then checker.possible_badge_merges.values.map(&:to_a)
      when :sure then checker.sure_badge_merges.values.map(&:to_a)
      when :relay_only then checker.relay_only_badges.to_a
      when :relay then checker.relay_badges.to_a
      end
    end

    # The outcomes of the candidates of a step (the progress callback runs outside the per-candidate rescue).
    def plan_step(step, candidates)
      state = { badges: Set.new, programs: Set.new }
      outcomes = candidates.each_with_index.map do |(source, dest), index|
        @progress&.call(index, candidates.size, "#{STEP_NAMES[step]}: badge #{source.id}")
        plan_candidate(source, dest, state)
      end
      @progress&.call(candidates.size, candidates.size, STEP_NAMES[step])
      outcomes
    end

    def plan_candidate(source, dest, state) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      mode = dest_team_id && dest && dest.team_id == dest_team_id ? :force : :autofix
      ids = [source.id, dest&.id].compact
      return outcome(source, dest, :deferred, mode, message: 'badge already planned in this step') if ids.any? { |id| state[:badges].include?(id) }

      lines = merger_lines(source, dest, mode)
      programs = lines.filter_map { |line| line.to_s.match(PROGRAM_INSERT_REGEXP)&.captures }
      if programs.any? { |tuple| state[:programs].include?(tuple) }
        return outcome(source, dest, :deferred, mode, message: 'meeting program inserted by another badge of this step')
      end

      state[:badges].merge(ids)
      state[:programs].merge(programs)
      outcome(source, dest, :planned, mode, sql_lines: lines)
    rescue StandardError => e
      outcome(source, dest, :failed, mode, message: "#{e.class}: #{e.message}".truncate(500))
    end

    # The single-transaction lines of one badge fix (what the former task wrote in one file per badge).
    def merger_lines(source, dest, mode)
      merger = if mode == :force
                 Merge::Badge.new(source:, dest:, force: true)
               else
                 Merge::Badge.new(source:, dest:, autofix: true)
               end
      merger.prepare
      merger.single_transaction_sql_log
    end

    def outcome(source, dest, status, mode, sql_lines: [], message: nil) # rubocop:disable Metrics/ParameterLists
      Outcome.new(source_id: source.id, dest_id: dest&.id, team_id: source.team_id, status:, mode:, sql_lines:, message:)
    end
  end
end
