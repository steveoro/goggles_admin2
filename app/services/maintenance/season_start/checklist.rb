# frozen_string_literal: true

module Maintenance
  module SeasonStart
    #
    # = Maintenance::SeasonStart::Checklist
    #
    # The ordered season-start checklist of one season (docs/HOWTO_prepare_new_season_at_championship_start.md):
    #   1. seasons_exist            Season row in the local DB (goggles_db data migration; instructions only)
    #   2. category_types           CategoryTypes of the season (goggles_db data migration; 'categories.clone' only as a
    #                               repair, when the local count is 0 and the remote season is known to exist)
    #   3. migrations               dev/test DBs migrated, test dump refreshed (tick box)
    #   4. standard_timings_file    the FIN source file in crawler/data/standard_timings/<season>/ (or uploaded there)
    #   5. standard_timings_import  'standard_timings.import' (applied locally, script HELD 'remote_season_missing')
    #   6. remote_season            GET season/:id on the configured API, on demand; releases the held scripts
    #   7. static_calendars         static calendar URLs checked (tick box)
    #   8. season_board_backfill    'season_board.backfill' applied for the season; SeasonDefaults now returns it
    # Steps 1, 2, 4, 5, 6 and 8 re-derive their state from the data on every view; 3 and 7 are the operator's
    # Ops::SeasonChecklistItem rows. A step is ready when every previous step is done (or skipped): the controller
    # refuses the POST of a step that is not ready.
    #
    # Never writes, never calls the remote API (step 6 reads the stored outcome of the last check).
    #
    class Checklist
      STEP_KEYS = %w[seasons_exist category_types migrations standard_timings_file standard_timings_import remote_season
                     static_calendars season_board_backfill].freeze
      OPERATOR_STEPS = %w[migrations static_calendars].freeze
      HOWTO_PATH = 'docs/HOWTO_prepare_new_season_at_championship_start.md'
      HELD_REASON = Maintenance::Operations::StandardTimingsImport::HELD_REASON

      # The standard timings folder (specs: a temporary one).
      class_attribute :standard_timings_dir, default: Import::StandardTimings::BASE_DIR

      attr_reader :season_id

      def initialize(season_id:)
        @season_id = season_id.to_i
      end

      def season
        return @season if defined?(@season)

        @season = GogglesDb::Season.find_by(id: season_id)
      end

      # The steps in order.
      def steps
        @steps ||= STEP_KEYS.each_with_object([]) do |key, list|
          ready = list.all?(&:finished?)
          list << send("#{key}_step", ready, list.size + 1)
        end
      end

      def step(key) = steps.find { |step| step.key == key.to_s }

      def done_count = steps.count(&:finished?)

      # The operator's row of a step (nil when none; never raises without the ops DB).
      def item(key) = items[key.to_s]

      # The standard-timings scripts of the season held until the remote season exists.
      def held_scripts
        Ops.safely([]) do
          Ops::SqlScript.where(season_id:, kind: 'standard_timings', state: 'held', held_reason: HELD_REASON).order(:seq).to_a
        end
      end

      # The source file of the season, as 'import:standard_timings' finds it (nil when none or no season).
      def standard_timings_file
        return unless season

        @standard_timings_file ||= Import::StandardTimings.new(season:, base_dir: standard_timings_dir).resolve_source_filename
      end

      # The season folder of the standard timings (uploads go there).
      def standard_timings_folder = Pathname.new(standard_timings_dir).join(season_id.to_s)

      # The id of the previous season of the same type (the source of a category clone).
      def previous_season_id
        return unless season

        GogglesDb::Season.where(season_type_id: season.season_type_id).where(id: ...season_id).order(:id).last&.id
      end

      private

      def items
        @items ||= Ops.safely({}) { Ops::SeasonChecklistItem.for_season(season_id).index_by(&:step_key) }
      end

      def build(key, number, kind, ready, done:, facts: [], action: nil, operation: nil, last_run: nil) # rubocop:disable Metrics/ParameterLists
        Step.new(key:, number:, kind:, done: done ? true : false, ready:, item: item(key), facts: facts.compact, action:,
                 operation:, last_run:)
      end

      def t(key, **options) = I18n.t("maintenance.season_start.steps.#{key}", **options)

      def seasons_exist_step(ready, number)
        facts = if season
                  siblings = GogglesDb::Season.where(header_year: season.header_year).where.not(id: season.id).order(:id)
                                              .map { |row| "#{row.id} (#{row.description})" }
                  [t('seasons_exist.exists', id: season.id, description: season.description),
                   (t('seasons_exist.siblings', list: siblings.join(', ')) if siblings.any?)]
                else
                  [t('seasons_exist.missing', id: season_id)]
                end
        build('seasons_exist', number, :data, ready, done: season.present?, facts:)
      end

      def category_types_step(ready, number)
        count = GogglesDb::CategoryType.unscoped.where(season_id:).count
        repair = count.zero? && season.present? && item('remote_season')&.done? && previous_season_id.present?
        build('category_types', number, :data, ready, done: count.positive?, facts: [t('category_types.count', count:)],
                                                      action: repair ? :repair : nil,
                                                      operation: repair ? clone_operation : nil)
      end

      def clone_operation
        { 'key' => 'categories.clone', 'params' => { 'src_season_id' => previous_season_id, 'dest_season_id' => season_id } }
      end

      def migrations_step(ready, number) = operator_step('migrations', number, ready)
      def static_calendars_step(ready, number) = operator_step('static_calendars', number, ready)

      def operator_step(key, number, ready)
        build(key, number, :operator, ready, done: item(key)&.done?, action: :confirm)
      end

      def standard_timings_file_step(ready, number)
        path = standard_timings_file
        facts = [path ? t('standard_timings_file.found', path: Outbox.relative_path(path, data_root: Rails.root)) : t('standard_timings_file.missing')]
        build('standard_timings_file', number, :data, ready, done: path.present?, facts:, action: :upload)
      end

      def standard_timings_import_step(ready, number)
        count = GogglesDb::StandardTiming.unscoped.where(season_id:).count
        held = held_scripts.size
        facts = [t('standard_timings_import.count', count:), (t('standard_timings_import.held', count: held) if held.positive?)]
        build('standard_timings_import', number, :operation, ready, done: count.positive?, facts:, action: :operation,
                                                                    operation: { 'key' => 'standard_timings.import', 'params' => { 'season_id' => season_id } },
                                                                    last_run: last_run('standard_timings.import'))
      end

      def remote_season_step(ready, number)
        row = item('remote_season')
        facts = if row&.done_at
                  [t('remote_season.checked', when: I18n.l(row.done_at.localtime, format: :short),
                                              result: t(row.done? ? 'remote_season.found' : 'remote_season.not_found'))]
                elsif row&.updated_at && row.note.present?
                  [row.note]
                else
                  [t('remote_season.never')]
                end
        build('remote_season', number, :remote, ready, done: row&.done? && held_scripts.empty?, facts:, action: :check_remote)
      end

      def season_board_backfill_step(ready, number)
        current = SeasonDefaults.default_season_id
        run = last_run('season_board.backfill', applied: true)
        default_fact = if current == season_id
                         t('season_board_backfill.default_ok', id: season_id)
                       else
                         t('season_board_backfill.default_mismatch', current: current || '-', id: season_id)
                       end
        facts = [default_fact, (t('season_board_backfill.runs') if run)]
        build('season_board_backfill', number, :operation, ready, done: current == season_id && run.present?, facts:, action: :operation,
                                                                  operation: { 'key' => 'season_board.backfill', 'params' => { 'season_id' => season_id } },
                                                                  last_run: run || last_run('season_board.backfill'))
      end

      # The latest run of an operation for the season (an applied one with +applied+).
      def last_run(key, applied: false)
        Ops.safely do
          scope = Ops::OperationRun.where(operation_key: key, season_id:)
          scope = scope.where(mode: 'apply', status: 'succeeded') if applied
          scope.order(id: :desc).first
        end
      end
    end
  end
end
