# frozen_string_literal: true

module Health
  #
  # = Health::Registry
  #
  # Catalogue of the closed-season data health checks (see docs/plans/done/06-season-health-report.md and
  # docs/season_board.md, "Data health"). Each check belongs to one group (Ops::HealthRun::GROUPS); a group is
  # run as a whole by one Health::Checks::<Group> class, which emits the findings of all its checks.
  #
  # == Check attributes
  # - key: stable dotted key (fingerprints and i18n keys 'health.checks.<key>.*' depend on it: never rename);
  # - group: group key; cost: :cheap (at most 3 grouped queries), :disk (one DiskIndex scan), :medium, :heavy
  #   (per-swimmer / per-meeting loops in an existing class);
  # - version: bump it when the check logic changes (stored on each run: a closed season is re-checked even with an
  #   unchanged data stamp);
  # - severities: the possible severities (the check class picks one per finding);
  # - subject_type: kind of subject of its findings;
  # - rake: optional command template (format references, filled from the finding payload 'rake' Hash);
  # - doc: optional repository file with the procedure;
  # - actions: what the finding detail offers in 06 (:flag_cancelled, :review, :push, :season_board, :ignore).
  # Texts: 'health.checks.<key>.title' (section title), '.finding' (finding title, interpolated with the
  # payload 'title_args'), '.howto' (what to do), in en and it.
  #
  class Registry
    Check = Data.define(:key, :group, :cost, :version, :severities, :subject_type, :rake, :doc, :actions) do
      # Section title (current locale).
      def title = I18n.t("health.checks.#{key}.title")

      # How-to text (current locale).
      def howto = I18n.t("health.checks.#{key}.howto")

      # The copyable command with the ids filled in from +args+ (Hash), or nil (no template or missing args).
      def rake_command(args)
        return if rake.blank?

        format(rake, **args.to_h.symbolize_keys)
      rescue KeyError, ArgumentError
        nil
      end

      def heavy? = %i[heavy medium disk].include?(cost)
    end

    GROUPS = Ops::HealthRun::GROUPS

    # Group key => check class name (each class runs every check of its group).
    GROUP_CLASSES = {
      'meetings' => 'Health::Checks::Meetings', 'badges' => 'Health::Checks::Badges', 'people' => 'Health::Checks::People',
      'results' => 'Health::Checks::Results', 'setup' => 'Health::Checks::Setup'
    }.freeze

    # Groups whose run can be skipped when the season data stamp is unchanged (see Health::Stamp).
    STAMP_SKIPPABLE_GROUPS = %w[badges people results].freeze

    MERGE_BADGE = 'bin/rails merge:badge src=%<src>s dest=%<dest>s autofix=1'

    def self.check(key, group, cost:, severities:, subject_type:, version: 1, rake: nil, doc: nil, actions: []) # rubocop:disable Metrics/ParameterLists
      Check.new(key:, group:, cost:, version:, severities:, subject_type:, rake:, doc:, actions:)
    end
    private_class_method :check

    CHECKS = [
      # meetings
      check('meetings.no_results.unflagged', 'meetings', cost: :cheap, severities: %w[error warning], subject_type: 'meeting',
                                                         actions: %i[ignore flag_cancelled]),
      check('meetings.no_results.source_on_disk', 'meetings', cost: :disk, severities: %w[error], subject_type: 'meeting',
                                                              actions: %i[review push]),
      check('meetings.cancel_mismatch', 'meetings', cost: :cheap, severities: %w[error warning], subject_type: 'meeting',
                                                    actions: %i[flag_cancelled ignore]),
      check('calendars.unlinked', 'meetings', cost: :cheap, severities: %w[error warning], subject_type: 'calendar',
                                              actions: %i[ignore flag_cancelled season_board]),
      check('meetings.no_events', 'meetings', cost: :cheap, severities: %w[warning info], subject_type: 'meeting',
                                              actions: %i[review ignore]),
      check('meetings.results_flag', 'meetings', cost: :cheap, severities: %w[warning], subject_type: 'season',
                                                 rake: 'bin/rails season_board:backfill season=%<season_id>s'),
      # badges (one Merge::BadgeSeasonChecker run)
      check('badges.duplicate.sure', 'badges', cost: :heavy, severities: %w[error], subject_type: 'swimmer', rake: MERGE_BADGE),
      check('badges.duplicate.possible', 'badges', cost: :heavy, severities: %w[warning], subject_type: 'swimmer', rake: MERGE_BADGE,
                                                   actions: %i[ignore]),
      check('badges.relay_category', 'badges', cost: :heavy, severities: %w[error], subject_type: 'badge',
                                               rake: 'bin/rails merge:badge src=%<src>s autofix=1'),
      check('teams.possible_duplicates', 'badges', cost: :heavy, severities: %w[warning], subject_type: 'teams',
                                                   rake: 'bin/rails check:team src=%<src>s dest=%<dest>s', actions: %i[ignore]),
      # people
      check('swimmers.possible_duplicates', 'people', cost: :medium, severities: %w[warning], subject_type: 'swimmers',
                                                      rake: 'bin/rails check:swimmer src=%<src>s dest=%<dest>s', actions: %i[ignore]),
      # results
      check('results.duplicates', 'results', cost: :heavy, severities: %w[error], subject_type: 'meeting',
                                             rake: 'bin/rails check:dup_mir_swimmers meeting_id=%<meeting_id>s autofix=1'),
      check('results.null_swimmers', 'results', cost: :cheap, severities: %w[error], subject_type: 'meeting',
                                                rake: 'bin/rails fix:nil_swimmers_in_results meeting_id=%<meeting_id>s'),
      check('results.dup_mir_per_badge', 'results', cost: :cheap, severities: %w[warning], subject_type: 'meeting',
                                                    rake: 'bin/rails check:dup_mir_badges meeting_id=%<meeting_id>s'),
      # setup
      check('season.setup', 'setup', cost: :cheap, severities: %w[error info], subject_type: 'season',
                                     doc: 'docs/HOWTO_prepare_new_season_at_championship_start.md')
    ].freeze

    CHECKS_BY_KEY = CHECKS.index_by(&:key).freeze

    class << self
      # All the checks, in catalogue order.
      def all = CHECKS

      # The check with the given key (nil when unknown).
      def find(key) = CHECKS_BY_KEY[key.to_s]

      # The check with the given key; raises KeyError when unknown.
      def fetch(key) = CHECKS_BY_KEY.fetch(key.to_s)

      # The checks of a group, in catalogue order.
      def for_group(group_key)
        CHECKS.select { |check| check.group == group_key.to_s }
      end

      def group_keys = GROUPS

      # The check class of a group (raises KeyError for an unknown group).
      def group_class(group_key)
        GROUP_CLASSES.fetch(group_key.to_s).constantize
      end

      # Hash check key => version for the group (stored on each run).
      def versions_for(group_key)
        for_group(group_key).to_h { |check| [check.key, check.version] }
      end

      def stamp_skippable?(group_key) = STAMP_SKIPPABLE_GROUPS.include?(group_key.to_s)
    end
  end
end
